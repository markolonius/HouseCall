-- Runs once, the first time the Postgres data volume is initialized.
-- Creates the separate database the test suite uses (TEST_DATABASE_URL).
-- The primary `housecall` database and `housecall` role come from the
-- POSTGRES_* environment variables in docker-compose.yml.
CREATE DATABASE housecall_test OWNER housecall;
