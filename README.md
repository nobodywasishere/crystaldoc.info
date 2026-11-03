# CrystalDoc.info

This is a website for hosting documentation of Crystal Shards.

## Development

CrystalDoc relies on a PostgreSQL database to hold all the information about the repositories. To create a local development version using docker:
```sh
$ docker run --name crystal_doc -p 5432:5432 -e POSTGRES_USER=crystal_doc_server -e POSTGRES_PASSWORD=password -e POSTGRES_DB=crystal_doc -d postgres
$ shards run -- micrate up
```

Edit the `config.yml`
```sh
$ cp example-config.yml config.yml
$ nano config.yml # Add API keys / database URL
```

The server can then be run with:
```sh
$ shards run -- server # or 'searcher', 'builder', etc.
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
Build with `--release -Dwithout_mt`, without `-Dpreview_mt`. The services launch subprocesses, and the
multithreaded build has left forked searcher children spinning in the GC callback in production.
`-Dwithout_mt` also explicitly selects the single-threaded scheduler on newer Crystal releases.
The runtime still runs concurrent I/O fibers. Use `builder --workers=COUNT` and
`searcher --workers=COUNT` to set job concurrency (defaults to 4); on the current single-CPU,
2 GB host, use one builder and one searcher to limit contention and compiler memory use.

```sh
$ shards build --release -Dwithout_mt
$ ./bin/crystaldoc server
# Run builder --workers=1 and searcher --workers=1 in separate services.
```

Each of the services outputs are logged to their respective log file in the `logs/` folder.

The production checkout is `/srv/crystaldoc.info`. Install the log rotation policy with
`sudo install -m 0644 config/logrotate.conf /etc/logrotate.d/crystaldoc` and validate it
with `sudo logrotate --debug /etc/logrotate.d/crystaldoc`. It keeps seven rotations per
service and uses `copytruncate` because the processes keep their log files open. A small
number of log lines can be lost between copying and truncation. `maxsize` is checked only
when logrotate runs (normally daily); an hourly logrotate timer is recommended on this host.
Do not force the first rotation until sufficient space is available for a copy of the
largest active log.

The reviewed server overrides are in `config/crystaldoc-builder.override.conf`,
`config/crystaldoc-searcher.override.conf`, and `config/logrotate-timer.override.conf`.
The first two belong under the corresponding
`~crystaldoc/.config/systemd/user/crystaldoc-{builder,searcher}.service.d/` directory;
reload the user manager and restart those services after installing them. The timer
override belongs under `/etc/systemd/system/logrotate.timer.d/`; reload the system
manager and restart `logrotate.timer`. `CRYSTAL_WORKERS=1` mitigates the old binary's
runtime parallelism until the next deploy replaces it with a `-Dwithout_mt` build.

In Nginx, use `proxy_pass http://127.0.0.1:3000/` and the corresponding IPv4 address in
`proxy_redirect`. The application listens on IPv4; `localhost` also resolves to `::1`,
which causes connection refusals and contributes to "no live upstreams" during stalls.
Validate with `sudo nginx -t` before reloading Nginx.

MCP's resource inventory is warmed at server startup. Directory traversal yields to the
HTTP scheduler, and expired inventories refresh in the background while requests use the
previous snapshot. A cold resource-list request waits for the initial scan, but other
requests continue to run. The inventory cache is published only after a successful scan.

## Contributing

1. Fork it (<https://github.com/nobodywasishere/crystaldoc.info/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Margret Riegert](https://github.com/nobodywasishere) - creator and maintainer
- [Gwen Dowling](https://github.com/ItsJustGeek) - maintainer
