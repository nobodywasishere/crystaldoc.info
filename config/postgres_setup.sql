CREATE USER crystal_doc_server WITH PASSWORD :CDS_PASSWORD;

CREATE SCHEMA crystal_doc AUTHORIZATION crystal_doc_server;

SET search_path TO crystal_doc;

CREATE TABLE repo (
    id int not null primary key generated always as identity,
    service text not null,
    username text not null,
    project_name text not null,
    source_url text not null,
    unique (service, username, project_name)
);

GRANT SELECT, INSERT ON repo TO crystal_doc_server;

CREATE TABLE repo_version (
    id int not null primary key generated always as identity,
    repo_id int references repo on delete cascade,
    commit_id text not null,
    nightly bool default false
);

GRANT SELECT, INSERT ON repo_version TO crystal_doc_server;

CREATE TABLE repo_latest_version (
    id int not null primary key generated always as identity,
    repo_id int unique references repo on delete cascade,
    latest_version int references repo_version
);

GRANT SELECT, INSERT, UPDATE ON repo_latest_version TO crystal_doc_server;

CREATE TABLE repo_status (
    id int not null primary key generated always as identity,
    repo_id int unique references repo on delete cascade,
    last_commit text not null,
    last_checked timestamptz not null
);

GRANT SELECT, INSERT, UPDATE ON repo_status TO crystal_doc_server;

CREATE TABLE doc_job (
    id int not null primary key generated always as identity,
    queue_time timestamptz default now(),
    priority int not null,
    version_id int unique references repo_version on delete cascade
);

GRANT SELECT, INSERT, DELETE ON doc_job TO crystal_doc_server;
