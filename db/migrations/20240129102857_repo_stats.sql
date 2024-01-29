-- +micrate Up
-- SQL in section 'Up' is executed when this migration is applied

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
