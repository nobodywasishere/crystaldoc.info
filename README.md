# CrystalDoc.info

This is a website for hosting documentation of Crystal Shards.

## Development

CrystalDoc relies on a PostgreSQL database to hold all the information about the repositories. To create a local development version using docker:
```sh
$ docker run --name crystal_doc -p 5432:5432 -e POSTGRES_USER=crystal_doc_server -e POSTGRES_PASSWORD=password -e POSTGRES_DB=crystal_doc -d postgres
$ psql -h localhost -U crystal_doc_server -f config/postgres_setup.sql
```

## Usage

CrystalDoc.info comprises of four components that work together to provide its functionality:
- A PostgreSQL database contains all of the repositories and versions, as well as a job queue for pending doc generation
- A server that's integrated into a static file server that handles the frontend and adding new repositories
- A searcher that checks each repository daily for new versions and main branch updates, inserting new doc generation jobs as necessary
- A builder which checks for new doc generation jobs, attempts to build them, and posts the generated files to the static file portion of the site

Each component can be modified separately and scaled up or down as necessary. For instance, if there is a sudden increase of doc jobs,
the number of builders can be manually increased to offset this, allowing for faster doc generation.

## Deployment

CrystalDoc.info uses a PostgreSQL database to store information about each of the repositories and their versions.
A database can be setup after initialization using the provided `config/postgres_setup.sql` script.
The URL to the database is then set via the `POSTGRES_DB` environment variable, including options for the connection pools.
See [here](https://crystal-lang.org/reference/1.9/database/connection_pool.html#configuration) for more information on the
connection pool settings.

After the database is setup, each of the 3 services can be setup and run in their own processes, for example, using systemd daemons.
It is recommended to build with `--release` and `-D=preview_mt` to provide the most performance. You can set the `CRYSTAL_WORKERS`
environment variable to set the number of builders and searchers to run at the same time (defaults to 4).

```sh
$ shards build crystaldoc_server --release -D=preview_mt
$ ./bin/crystaldoc_server
# repeat for crystaldoc_builder and crystaldoc_searcher
```

Each of the services outputs are logged to their respective log file in the `logs/` folder.

## Contributing

1. Fork it (<https://github.com/nobodywasishere/crystaldoc.info/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Margret Riegert](https://github.com/nobodywasishere) - creator and maintainer
- [Gwen Dowling](https://github.com/ItsJustGeek) - maintainer
