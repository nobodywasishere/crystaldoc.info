-- +micrate Up
-- SQL in section 'Up' is executed when this migration is applied

CREATE SCHEMA crystal_doc AUTHORIZATION crystal_doc_server;

CREATE TABLE crystal_doc.repo (
    id int not null primary key generated always as identity,
    service text not null,
    username text not null,
    project_name text not null,
    source_url text not null,
    build_type text not null default 'git',
    unique (service, username, project_name)
);

GRANT SELECT, INSERT ON crystal_doc.repo TO crystal_doc_server;

CREATE TABLE crystal_doc.repo_version (
    id int not null primary key generated always as identity,
    repo_id int references crystal_doc.repo on delete cascade,
    commit_id text not null,
    nightly bool default false,
    valid bool default false,
    unique (repo_id, commit_id)
);

GRANT SELECT, INSERT ON crystal_doc.repo_version TO crystal_doc_server;

CREATE TABLE crystal_doc.repo_latest_version (
    id int not null primary key generated always as identity,
    repo_id int unique references crystal_doc.repo on delete cascade,
    latest_version int references crystal_doc.repo_version
);

GRANT SELECT, INSERT, UPDATE ON crystal_doc.repo_latest_version TO crystal_doc_server;

CREATE TABLE crystal_doc.repo_status (
    id int not null primary key generated always as identity,
    repo_id int unique references crystal_doc.repo on delete cascade,
    last_commit text not null,
    last_checked timestamptz not null
);

GRANT SELECT, INSERT, UPDATE ON crystal_doc.repo_status TO crystal_doc_server;

CREATE TABLE crystal_doc.doc_job (
    id int not null primary key generated always as identity,
    queue_time timestamptz default now(),
    priority int not null,
    version_id int unique references crystal_doc.repo_version on delete cascade
);

GRANT SELECT, INSERT, UPDATE, DELETE ON crystal_doc.doc_job TO crystal_doc_server;

CREATE TABLE crystal_doc.featured_repo (
    id int not null primary key generated always as identity,
    repo_id int unique references crystal_doc.repo on delete cascade
);

GRANT SELECT, INSERT, UPDATE, DELETE ON crystal_doc.featured_repo TO crystal_doc_server;

CREATE TABLE crystal_doc.repo_stats (
    id int not null primary key generated always as identity,
    repo_id int unique references crystal_doc.repo on delete cascade,
    stars int default null,
    fork bool default false
);

GRANT SELECT, INSERT, UPDATE, DELETE ON crystal_doc.repo_stats TO crystal_doc_server;


-- +micrate Down
-- SQL section 'Down' is executed when this migration is rolled back

DROP TABLE repo_stats CASCADE;
REVOKE ALL PRIVILEGES ON repo_stats FROM crystal_doc_server;

DROP TABLE featured_repo CASCADE;
REVOKE ALL PRIVILEGES ON featured_repo FROM crystal_doc_server;

DROP TABLE doc_job CASCADE;
REVOKE ALL PRIVILEGES ON doc_job FROM crystal_doc_server;

DROP TABLE repo_status CASCADE;
REVOKE ALL PRIVILEGES ON repo_status FROM crystal_doc_server;

DROP TABLE repo_latest_version CASCADE;
REVOKE ALL PRIVILEGES ON repo_latest_version FROM crystal_doc_server;

DROP TABLE repo_version CASCADE;
REVOKE ALL PRIVILEGES ON repo_version FROM crystal_doc_server;

DROP TABLE repo CASCADE;
REVOKE ALL PRIVILEGES ON repo FROM crystal_doc_server;

DROP USER crystal_doc_server;
