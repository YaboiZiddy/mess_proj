-- Pure DDL: structure only, no data - run via sqlite3.executescript()
--
-- Conventions
--   * Timestamps are ISO 8601 / RFC 3339 UTC text: 'YYYY-MM-DDTHH:MM:SSZ', produced
--     by strftime('%Y-%m-%dT%H:%M:%SZ', 'now'). Application code MUST write timestamps
--     in this exact form so lexicographic order == chronological order. Never 'DD/MM/YYYY'.
--   * id INTEGER PRIMARY KEY aliases rowid; ids may be reused after deletion.
--   * PRAGMA foreign_keys = ON and PRAGMA journal_mode = WAL are issued per connection
--     in db.py, not here. The composite foreign keys below do nothing without them.
--   * Mess scoping: every table filtered by the acting user's mess carries its own
--     mess_id, so the filter lives in the SQL WHERE clause, never in Python.
--
-- Personal data (GDPR / Data Protection Act 2018)
--   Everything in people, plus tickets.reporter_contact, is personal data. Erasure is
--   performed by overwriting those columns in place and setting deleted_at - rows are
--   never hard-deleted, so ticket history and foreign keys stay intact. Backups age out
--   on a documented retention window. Production-grade crypto-shredding is noted in the README.

CREATE TABLE barracks (
    id   INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE
);

CREATE TABLE messes (
    id          INTEGER PRIMARY KEY,
    barracks_id INTEGER NOT NULL REFERENCES barracks(id),
    name        TEXT,                                   -- optional display name; real composition is barracks + mess_type
    mess_type   TEXT NOT NULL CHECK (mess_type IN ('private', 'nco', 'officer')),
    UNIQUE (barracks_id, mess_type)                     -- at most one mess of each type per barracks
);

CREATE TABLE rooms (
    id              INTEGER PRIMARY KEY,
    mess_id         INTEGER NOT NULL REFERENCES messes(id),
    room_number     TEXT NOT NULL,
    floor           INTEGER NOT NULL,
    room_type       TEXT NOT NULL CHECK (room_type IN ('standard', 'vip')),
    ensuite         INTEGER NOT NULL CHECK (ensuite IN (0, 1)),
    habitable       INTEGER NOT NULL DEFAULT 1 CHECK (habitable IN (0, 1)),
    max_occupancy   INTEGER NOT NULL CHECK (max_occupancy > 0),
    last_updated    TEXT,                               -- ISO 8601 UTC; NULL until first edit
    last_updated_by INTEGER REFERENCES users(id),
    UNIQUE (mess_id, room_number),
    UNIQUE (id, mess_id)                                -- lets child rows pin (room, mess) via a composite FK
);

-- App logins. Only these people can use the app.
--   worker    - log and resolve tickets in their assigned mess
--   secretary - everything a worker can, plus room and roster management
--   org       - national occupancy oversight; read-only; not scoped to a mess
CREATE TABLE users (
    id            INTEGER PRIMARY KEY,
    person_id     INTEGER UNIQUE REFERENCES people(id),  -- their roster entry, when they also live in a mess; else NULL
    username      TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    role          TEXT NOT NULL CHECK (role IN ('worker', 'secretary', 'org')),
    mess_id       INTEGER REFERENCES messes(id),
    deleted_at    TEXT,                                  -- ISO 8601 UTC; NULL = active
    CHECK ((role = 'org') = (mess_id IS NULL))           -- org has no mess; worker/secretary must have one
);

-- Roster of every mess inhabitant, maintained by each mess's secretary. A worker or
-- secretary who also lives in a mess appears here too and is linked from users.person_id;
-- their residence mess (this row) may differ from the mess they work in (users.mess_id),
-- but both are in the same barracks.
CREATE TABLE people (
    id          INTEGER PRIMARY KEY,
    mess_id     INTEGER NOT NULL REFERENCES messes(id),  -- whose roster this entry is on
    first_name  TEXT NOT NULL,
    last_name   TEXT NOT NULL,
    rank        TEXT CHECK (rank IN (
                    -- USER: replace this single placeholder with the real rank list, e.g.
                    --   'Pte', 'Cpl', 'Sgt', 'CQMS', 'CS', 'Lt', 'Capt', 'Comdt', 'Lt Col', 'Col'
                    '__REPLACE_ME__'
                )),
    army_number TEXT UNIQUE,
    phone       TEXT,
    room_id     INTEGER,                                 -- NULL until assigned a room
    deleted_at  TEXT,                                    -- ISO 8601 UTC; NULL = current. Erasure = overwrite PII + set this.
    FOREIGN KEY (room_id, mess_id) REFERENCES rooms(id, mess_id)  -- assigned room must be in this person's mess
);

CREATE TABLE tickets (
    id               INTEGER PRIMARY KEY,
    mess_id          INTEGER NOT NULL REFERENCES messes(id),  -- always set, so ticket lists scope without a join
    room_id          INTEGER,                                 -- NULL for a mess-wide / common-area fault
    location         TEXT,                                    -- required when room_id is NULL (e.g. 'boiler room')
    description      TEXT NOT NULL,
    status           TEXT NOT NULL DEFAULT 'outstanding'
                         CHECK (status IN ('outstanding', 'in_progress', 'resolved')),
    date_reported    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    date_resolved    TEXT,
    reported_by      INTEGER NOT NULL REFERENCES users(id),   -- staff member who entered the ticket
    resolved_by      INTEGER REFERENCES users(id),            -- staff member who closed it
    reporter_id      INTEGER REFERENCES people(id),           -- inhabitant who raised it, when on the roster
    reporter_contact TEXT,                                    -- free-text fallback (name / phone) when not
    FOREIGN KEY (room_id, mess_id) REFERENCES rooms(id, mess_id),
    CHECK (room_id IS NOT NULL OR location IS NOT NULL),
    CHECK (date_resolved IS NULL OR date_resolved >= date_reported),
    CHECK ((resolved_by IS NULL) = (date_resolved IS NULL)),
    CHECK (date_resolved IS NULL OR status = 'resolved')
);

CREATE UNIQUE INDEX idx_one_secretary_per_mess
    ON users (mess_id) WHERE role = 'secretary';

-- Predictable from the access patterns and the mess-scoping rule:
CREATE INDEX idx_rooms_mess   ON rooms (mess_id);
CREATE INDEX idx_users_mess   ON users (mess_id);
CREATE INDEX idx_people_mess  ON people (mess_id);
CREATE INDEX idx_people_room  ON people (room_id);
CREATE INDEX idx_tickets_mess ON tickets (mess_id, status);
CREATE INDEX idx_tickets_room ON tickets (room_id, status);
-- Add any further indexes in response to real query plans (roadmap Phase 8.4), not on instinct.
