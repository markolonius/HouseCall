package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/markolonius/housecall/backend/internal/agent"
	"github.com/markolonius/housecall/backend/internal/api"
	"github.com/markolonius/housecall/backend/internal/migrate"
	"github.com/markolonius/housecall/backend/internal/store"
)

func main() {
	cmd := flag.String("cmd", "serve", "command: serve | migrate")
	addr := flag.String("addr", ":8080", "listen address for serve")
	migrationsDir := flag.String("migrations", "migrations", "path to migrations directory")
	flag.Parse()

	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		log.Fatal("DATABASE_URL is required")
	}

	switch *cmd {
	case "migrate":
		if err := runMigrate(dsn, *migrationsDir); err != nil {
			log.Fatalf("migrate: %v", err)
		}
	case "serve":
		if err := runServe(dsn, *addr); err != nil {
			log.Fatalf("serve: %v", err)
		}
	default:
		log.Fatalf("unknown cmd %q", *cmd)
	}
}

func runMigrate(dsn, dir string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		return fmt.Errorf("connect: %w", err)
	}
	defer conn.Close(ctx)

	applied, err := migrate.Apply(ctx, conn, os.DirFS(dir))
	if err != nil {
		return err
	}
	if len(applied) == 0 {
		fmt.Println("migrate: schema already up to date")
		return nil
	}
	for _, v := range applied {
		fmt.Printf("migrate: applied %s\n", v)
	}
	return nil
}

func runServe(dsn, addr string) error {
	secret := []byte(os.Getenv("JWT_SECRET"))
	if len(secret) < 16 {
		log.Fatal("JWT_SECRET must be set and at least 16 characters")
	}

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		return fmt.Errorf("pool: %w", err)
	}
	defer pool.Close()

	if err := pool.Ping(ctx); err != nil {
		return fmt.Errorf("ping: %w", err)
	}

	s := store.New(pool)

	// Two-phase construction breaks the circular dependency:
	//   Router → Drafter → Router (as PhysicianNotifier).
	//
	// 1. Build Router with no drafter yet.
	rt := api.New(s, secret)

	// 2. Build Drafter pointing at the Router (which satisfies
	//    agent.PhysicianNotifier via rt.SendToPhysicians).
	agentCfg := agent.ClientConfigFromEnv()
	log.Printf("agent: model config %s", agentCfg)
	drafter := agent.NewDrafter(agent.NewClient(agentCfg, nil), s, rt)

	// 3. Wire the drafter into the Router before the server starts accepting
	//    requests.
	rt.SetDrafter(drafter)

	r := chi.NewRouter()
	r.Use(middleware.RequestID)
	r.Use(middleware.Recoverer)

	r.Get("/healthz", func(w http.ResponseWriter, req *http.Request) {
		if err := pool.Ping(req.Context()); err != nil {
			http.Error(w, "db unreachable", http.StatusServiceUnavailable)
			return
		}
		_, _ = w.Write([]byte("ok"))
	})

	rt.Mount(r)

	srv := &http.Server{
		Addr:              addr,
		Handler:           r,
		ReadHeaderTimeout: 5 * time.Second,
	}

	go func() {
		log.Printf("server listening on %s", addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("listen: %v", err)
		}
	}()

	<-ctx.Done()
	log.Println("shutdown signal received")

	shutdownCtx, cancelShutdown := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancelShutdown()
	return srv.Shutdown(shutdownCtx)
}
