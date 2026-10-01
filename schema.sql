-- Conventions
--   * Timestamps are ISO 8601 / RFC 3339 UTC text: 'YYYY-MM-DDTHH:MM:SSZ', produced
--     by strftime('%Y-%m-%dT%H:%M:%SZ', 'now'). Application code MUST write timestamps
--     in this exact form so lexicographic order == chronological order. Never 'DD/MM/YYYY'.
--     Each timestamp column has a GLOB check, so a malformed write fails loudly.
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
--   on a retention window.

CREATE TABLE barracks (
    id   INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE -- for differentiating barracks and messes for each barracks
);

CREATE TABLE messes (
    id          INTEGER PRIMARY KEY,
    barracks_id INTEGER NOT NULL REFERENCES barracks(id),
    name        TEXT, -- display name; required for training accom, else optional
    mess_type   TEXT NOT NULL CHECK (mess_type IN ('private', 'nco', 'officer', 'training')),
    UNIQUE (barracks_id, name),
    UNIQUE (id, barracks_id), -- lets user_messes pin (mess, barracks) via a composite FK
    CHECK (mess_type <> 'training' OR name IS NOT NULL) -- several training messes per barracks need telling apart
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
    last_updated    TEXT CHECK (last_updated GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'),  -- NULL until first edit, ISO 8601 date format checker
    last_updated_by INTEGER REFERENCES users(id),
    UNIQUE (mess_id, room_number),
    UNIQUE (id, mess_id), -- lets child rows pin (room, mess) via a composite FK
    CHECK ((last_updated IS NULL) = (last_updated_by IS NULL))
);

-- App logins. Only these people can use the app.
-- user name should be DF email, password should be DF password
-- worker    - view, log and resolve tickets in their assigned messes
-- secretary - everything a worker can, plus room and roster management
-- org     - national occupancy oversight; read-only; not scoped to a mess
-- Mess assignments live in user_messes, all within the user's barracks.
CREATE TABLE users (
    id            INTEGER PRIMARY KEY,
    person_id     INTEGER UNIQUE REFERENCES people(id), -- their roster entry, when they also live in a mess; else NULL
    username      TEXT NOT NULL, -- unique among active users: see idx_users_username
    password_hash TEXT NOT NULL,
    role          TEXT NOT NULL CHECK (role IN ('worker', 'secretary', 'org')),
    barracks_id   INTEGER REFERENCES barracks(id), -- the barracks a worker/secretary works in
    deleted_at    TEXT CHECK (deleted_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'),  -- NULL = active, ISO 8601
    UNIQUE (id, role, barracks_id), -- target for user_messes' composite FK
    CHECK ((role = 'org') = (barracks_id IS NULL)) -- org has no barracks; worker/secretary must have one
);

-- Which messes each worker/secretary works in; e.g. one secretary may run a barracks'
-- private mess and its recruit accommodation. org users have no rows here: the role
-- CHECK excludes 'org' and the composite FK ties this role to users.role.
-- barracks_id must match both the user's and the mess's barracks, so a user can only be
-- assigned to messes in their own barracks.
-- Soft-deleting a user deletes their rows here; assignments are current state, not history.
-- Changing users.barracks_id is rejected while assignments exist: delete them first, in
-- the same transaction.
CREATE TABLE user_messes (
    user_id     INTEGER NOT NULL,
    mess_id     INTEGER NOT NULL,
    role        TEXT    NOT NULL CHECK (role IN ('worker', 'secretary')),
    barracks_id INTEGER NOT NULL,
    PRIMARY KEY (user_id, mess_id),
    FOREIGN KEY (user_id, role, barracks_id) REFERENCES users(id, role, barracks_id) ON UPDATE CASCADE,
    FOREIGN KEY (mess_id, barracks_id)       REFERENCES messes(id, barracks_id)
);

-- Roster of every mess inhabitant, maintained by each mess's secretary. A worker or
-- secretary who also lives in a mess appears here too and is linked from users.person_id;
-- their residence mess (this row) may differ from the messes they work in (user_messes),
-- but all are in the same barracks.
CREATE TABLE people (
    id          INTEGER PRIMARY KEY,
    mess_id     INTEGER NOT NULL REFERENCES messes(id), -- whose roster this entry is on
    first_name  TEXT NOT NULL,
    last_name   TEXT NOT NULL,
    rank        TEXT CHECK (rank IN (
                    'Rec', 'Pte', 'Cpl', 'Sgt', 'CS', 'CQMS', 'Sgt Mjr', 'Cdt', '2Lt', 'Lt', 'Capt', 'Comdt', 'Lt Col', 'Col'
                )),
    army_number TEXT, -- unique among current rows: see idx_people_army_number
    phone       TEXT,
    room_id     INTEGER, -- NULL until assigned a room
    deleted_at  TEXT CHECK (deleted_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'),  -- NULL = current. Erasure = overwrite PII + set this
    UNIQUE (id, mess_id), -- lets tickets pin (reporter, mess) via a composite FK
    FOREIGN KEY (room_id, mess_id) REFERENCES rooms(id, mess_id), -- assigned room must be in this person's mess
    CHECK (deleted_at IS NULL OR room_id IS NULL) -- a removed person no longer occupies a room
);

CREATE TABLE tickets (
    id               INTEGER PRIMARY KEY,
    mess_id          INTEGER NOT NULL REFERENCES messes(id), -- always set, so ticket lists scope without a join
    room_id          INTEGER, -- NULL for a mess-wide / common-area fault
    location         TEXT, -- required when room_id is NULL (e.g. 'boiler room')
    description      TEXT NOT NULL,
    status           TEXT NOT NULL DEFAULT 'outstanding'
                         CHECK (status IN ('outstanding', 'in_progress', 'resolved')),
    date_reported    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
                         CHECK (date_reported GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'),
    date_resolved    TEXT CHECK (date_resolved GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'),
    reported_by      INTEGER NOT NULL REFERENCES users(id), -- staff member who entered the ticket
    resolved_by      INTEGER REFERENCES users(id), -- staff member who closed it
    reporter_id      INTEGER, -- inhabitant who raised it, when on this mess's roster
    reporter_contact TEXT, -- free-text fallback (name / phone) when not
    FOREIGN KEY (room_id, mess_id)     REFERENCES rooms(id, mess_id),
    FOREIGN KEY (reporter_id, mess_id) REFERENCES people(id, mess_id), -- reporter must be on this mess's roster
    CHECK (room_id IS NOT NULL OR location IS NOT NULL),
    CHECK (date_resolved IS NULL OR date_resolved >= date_reported),
    CHECK ((resolved_by IS NULL) = (date_resolved IS NULL)),
    CHECK ((status = 'resolved') = (date_resolved IS NOT NULL))
);

CREATE UNIQUE INDEX idx_one_private_nco_officer_mess_per_barracks
    ON messes (barracks_id, mess_type) WHERE mess_type <> 'training';

CREATE UNIQUE INDEX idx_one_secretary_per_mess
    ON user_messes (mess_id) WHERE role = 'secretary';

-- Deleted users free their username for reuse; tickets keep pointing at the old user's id
CREATE UNIQUE INDEX idx_users_username
    ON users (username) WHERE deleted_at IS NULL;

-- Soft-deleted rows keep their army_number, so uniqueness applies to current rows only
CREATE UNIQUE INDEX idx_people_army_number
    ON people (army_number) WHERE deleted_at IS NULL;

-- Predictable from the access patterns and the mess-scoping rule:
CREATE INDEX idx_user_messes_mess ON user_messes (mess_id);
CREATE INDEX idx_people_mess  ON people (mess_id);
CREATE INDEX idx_people_room  ON people (room_id);
CREATE INDEX idx_tickets_mess ON tickets (mess_id, status);
CREATE INDEX idx_tickets_room ON tickets (room_id, status);
