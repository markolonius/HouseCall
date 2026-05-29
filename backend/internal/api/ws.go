package api

import (
	"io"
	"net/http"
	"sync"

	"github.com/coder/websocket"
	"github.com/google/uuid"
)

// Hub tracks active WebSocket connections keyed by actor ID. It is safe for
// concurrent use.
type Hub struct {
	mu    sync.Mutex
	conns map[string]*hubConn
}

type hubConn struct {
	tenantID  string
	actorType string // "patient" | "physician"
	send      chan []byte
}

func newHub() *Hub {
	return &Hub{conns: make(map[string]*hubConn)}
}

func (h *Hub) register(actorID, actorType, tenantID string) chan []byte {
	ch := make(chan []byte, 16)
	h.mu.Lock()
	h.conns[actorID] = &hubConn{tenantID: tenantID, actorType: actorType, send: ch}
	h.mu.Unlock()
	return ch
}

func (h *Hub) unregister(actorID string) {
	h.mu.Lock()
	delete(h.conns, actorID)
	h.mu.Unlock()
}

// SendToPatient delivers event to the patient identified by patientID in
// tenantID. Silently drops if the patient is not connected.
func (h *Hub) SendToPatient(tenantID, patientID string, event []byte) {
	h.mu.Lock()
	c, ok := h.conns[patientID]
	h.mu.Unlock()
	if !ok || c.tenantID != tenantID {
		return
	}
	select {
	case c.send <- event:
	default:
	}
}

// SendToPhysicians broadcasts event to all connected physicians in tenantID.
func (h *Hub) SendToPhysicians(tenantID string, event []byte) {
	h.mu.Lock()
	var chs []chan []byte
	for _, c := range h.conns {
		if c.tenantID == tenantID && c.actorType == "physician" {
			chs = append(chs, c.send)
		}
	}
	h.mu.Unlock()
	for _, ch := range chs {
		select {
		case ch <- event:
		default:
		}
	}
}

// handleWS upgrades the connection after validating the JWT supplied as the
// ?token= query parameter (used by mobile clients that cannot set headers
// on WebSocket upgrades).
func (rt *Router) handleWS(w http.ResponseWriter, r *http.Request) {
	token := r.URL.Query().Get("token")
	if token == "" {
		token = bearerToken(r)
	}
	if token == "" {
		http.Error(w, "missing token", http.StatusUnauthorized)
		return
	}
	rc, err := verifyToken(rt.secret, token)
	if err != nil {
		http.Error(w, "invalid token", http.StatusUnauthorized)
		return
	}
	actorID, err := uuid.Parse(rc.ActorID)
	if err != nil {
		http.Error(w, "invalid token", http.StatusUnauthorized)
		return
	}

	// InsecureSkipVerify allows mobile/non-browser clients whose Origin header
	// does not match the server host.
	c, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
	if err != nil {
		return
	}
	defer c.CloseNow()

	send := rt.hub.register(actorID.String(), rc.ActorType, rc.TenantID)
	defer rt.hub.unregister(actorID.String())

	ctx := r.Context()

	// Drain incoming frames; the server does not currently accept client messages.
	go func() {
		for {
			_, reader, err := c.Reader(ctx)
			if err != nil {
				return
			}
			_, _ = io.Copy(io.Discard, reader)
		}
	}()

	for {
		select {
		case msg, ok := <-send:
			if !ok {
				return
			}
			if err := c.Write(ctx, websocket.MessageText, msg); err != nil {
				return
			}
		case <-ctx.Done():
			return
		}
	}
}
