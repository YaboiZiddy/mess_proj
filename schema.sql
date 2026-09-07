-- Pure DDL: structure only, no data - Run via sqlite3.executescript()

CREATE TABLE messes (
    id            INTEGER PRIMARY KEY,
    name          TEXT NOT NULL,
    home_barracks TEXT NOT NULL,
    mess_type     TEXT NOT NULL CHECK (mess_type IN ('private', 'nco', 'officer')),
    max_occupancy INTEGER NOT NULL CHECK (max_occupancy > 0)
);

CREATE TABLE rooms (
    id          INTEGER PRIMARY KEY,
    mess_id     INTEGER NOT NULL REFERENCES messes(id),
    room_number TEXT NOT NULL,
    room_type   TEXT NOT NULL CHECK (room_type IN ('standard', 'vip')),
    ensuite     INTEGER NOT NULL CHECK (ensuite IN (0, 1)),
    habitable   INTEGER NOT NULL DEFAULT 1 CHECK (habitable IN (0, 1)),
    UNIQUE (mess_id, room_number)
);

CREATE TABLE people (
    id          INTEGER PRIMARY KEY,
    first_name  TEXT NOT NULL,
    last_name   TEXT NOT NULL,
    rank        TEXT,
    army_number TEXT UNIQUE,
    phone       TEXT,
    room_id     INTEGER REFERENCES rooms(id),
    staff_mess  INTEGER REFERENCES messes(id),
    title       TEXT CHECK (title IN ('groundskeeper', 'chef', 'secretary'))
);

CREATE UNIQUE INDEX idx_one_secretary_per_mess
    ON people (staff_mess)
    WHERE title = 'secretary';

CREATE INDEX idx_rooms_mess       ON rooms (mess_id);
CREATE INDEX idx_people_room      ON people (room_id);
CREATE INDEX idx_people_staff     ON people (staff_mess);