CREATE TABLE
  public.micrate_db_version (
    id serial NOT NULL,
    version_id bigint NOT NULL,
    is_applied boolean NOT NULL,
    tstamp timestamp without time zone NULL DEFAULT now()
  );

ALTER TABLE
  public.micrate_db_version
ADD
  CONSTRAINT micrate_db_version_pkey PRIMARY KEY (id)

INSERT INTO public.micrate_db_version ("id", "is_applied", "tstamp", "version_id") values (1, true, '2024-01-29 15:12:46.117382', '20240129083342')
