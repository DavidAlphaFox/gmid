/*
 * Copyright (c) 2022 Omar Polo <op@omarpolo.com>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */

#include "gmid.h"

#include <sys/stat.h>
#include <sys/wait.h>

#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <libgen.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>

struct imsgbuf ibuf, logibuf;
struct conf conf;

struct fcgi fcgi[FCGI_MAX];	/* just because it's referenced */
struct vhosthead hosts;


static const struct option opts[] = {
	{"help",	no_argument,	NULL,	'h'},
	{"version",	no_argument,	NULL,	'V'},
	{NULL,		0,		NULL,	0},
};

void
load_local_cert(struct vhost *h, const char *hostname, const char *dir)
{
	char *cert, *key;

	if (asprintf(&cert, "%s/%s.cert.pem", dir, hostname) == -1)
		errx(1, "asprintf");
	if (asprintf(&key, "%s/%s.key.pem", dir, hostname) == -1)
		errx(1, "asprintf");

	if (access(cert, R_OK) == -1 || access(key, R_OK) == -1)
		gen_certificate(hostname, cert, key);

	strlcpy(h->cert, cert, sizeof(h->cert));
	strlcpy(h->key, key, sizeof(h->key));
	strlcpy(h->domain, hostname, sizeof(h->domain));
}

/* wrapper around dirname(3).  dn must be PATH_MAX+1 at least. */
static void
pdirname(const char *path, char *dn)
{
	char	 p[PATH_MAX+1];
	char	*t;

	strlcpy(p, path, sizeof(p));
	t = dirname(p);
	memmove(dn, t, strlen(t)+1);
}

static void
mkdirs(const char *path, mode_t mode)
{
	char	dname[PATH_MAX+1];

	pdirname(path, dname);
	if (!strcmp(dname, "/"))
		return;
	mkdirs(dname, mode);
	if (mkdir(path, mode) != 0 && errno != EEXIST)
		fatal("can't mkdir %s: %s", path, strerror(errno));
}

/* $XDG_DATA_HOME/gmid */
char *
data_dir(void)
{
	const char *home, *xdg;
	char *t;

	if ((xdg = getenv("XDG_DATA_HOME")) == NULL) {
		if ((home = getenv("HOME")) == NULL)
			errx(1, "XDG_DATA_HOME and HOME both empty");
		if (asprintf(&t, "%s/.local/share/gmid", home) == -1)
			err(1, "asprintf");
	} else {
		if (asprintf(&t, "%s/gmid", xdg) == -1)
			err(1, "asprintf");
	}

	mkdirs(t, 0755);
	return t;
}

static void
logger_init(void)
{
	int p[2];

	if (socketpair(AF_UNIX, SOCK_STREAM, PF_UNSPEC, p) == -1)
		err(1, "socketpair");

	switch (fork()) {
	case -1:
		err(1, "fork");
	case 0:
		close(p[0]);
		setproctitle("logger");
		imsg_init(&logibuf, p[1]);
		_exit(logger_main(p[1], &logibuf));
	default:
		close(p[1]);
		imsg_init(&logibuf, p[0]);
		return;
	}
}

static int
serve(const char *host, int port, const char *dir, struct tls *ctx)
{
	struct addrinfo hints, *res, *res0;
	int error, saved_errno, sock = -1;
	const char *cause = NULL;
	char service[32];

	if (snprintf(service, sizeof(service), "%d", port) < 0)
		fatal("snprintf");

	memset(&hints, 0, sizeof(hints));
	hints.ai_family = AF_UNSPEC;
	hints.ai_socktype = SOCK_STREAM;
	hints.ai_flags = AI_PASSIVE;
	error = getaddrinfo(host, service, &hints, &res0);
	if (error)
		fatal("%s", gai_strerror(error));
	for (res = res0; res; res = res->ai_next) {
		sock = socket(res->ai_family, res->ai_socktype,
		    res->ai_protocol);
		if (sock == -1) {
			cause = "socket";
			continue;
		}

		if (bind(sock, res->ai_addr, res->ai_addrlen) == -1) {
			cause = "bind";
			saved_errno = errno;
			close(sock);
			errno = saved_errno;
			continue;
		}

		if (listen(sock, 5) == -1)
			fatal("listen");

		/*
		 * for the time being, we're happy as soon as
		 * something binds.
		 */
		break;
	}

	if (sock == -1)
		fatal("%s", cause);
	freeaddrinfo(res0);

	log_notice(NULL, "serving %s on port %d", dir, port);
	loop(ctx, sock, -1, NULL);
	return 0;
}

static __dead void
usage(void)
{
	fprintf(stderr,
	    "Version: " GE_STRING "\n"
	    "Usage: %s [-hVv] [-d certs-dir] [-H hostname] [-p port] [dir]\n",
	    getprogname());
	exit(1);
}

int
main(int argc, char **argv)
{
	struct tls_config *tlsconf;
	struct tls *ctx;
	struct vhost *host;
	struct location *loc;
	const char *errstr, *certs_dir = NULL, *hostname = "localhost";
	char path[PATH_MAX];
	int ch;

	logger_init();
	conf.port = 1965;

	while ((ch = getopt_long(argc, argv, "d:H:hp:Vv", opts, NULL)) != -1) {
		switch (ch) {
		case 'd':
			certs_dir = optarg;
			break;
		case 'H':
			hostname = optarg;
			break;
		case 'h':
			usage();
			break;
		case 'p':
			conf.port = strtonum(optarg, 0, UINT16_MAX, &errstr);
			if (errstr)
				fatal("port number is %s: %s", errstr, optarg);
			break;
		case 'V':
			puts("Version: " GE_STRING);
			return 0;
		default:
			usage();
			break;
		}
	}
	argc -= optind;
	argv += optind;

	if (argc > 1)
		usage();

	/* prepare the configuration */
	conf.verbose = 1;
	init_mime(&conf.mime);

	if (certs_dir == NULL)
		certs_dir = data_dir();

	if (load_default_mime(&conf.mime) == -1)
		fatal("can't load default mime types");
	sort_mime(&conf.mime);

	/* set up the implicit vhost and location */

	host = xcalloc(1, sizeof(*host));
	TAILQ_INSERT_HEAD(&hosts, host, vhosts);

	loc = xcalloc(1, sizeof(*loc));
	loc->fcgi = -1;
	TAILQ_INSERT_HEAD(&host->locations, loc, locations);

	load_local_cert(host, hostname, certs_dir);

	strlcpy(host->domain, "*", sizeof(host->domain));
	loc->auto_index = 1;
	strlcpy(loc->match, "*", sizeof(loc->match));

	if (*argv == NULL) {
		if (getcwd(path, sizeof(path)) == NULL)
			fatal("getcwd");
		strlcpy(loc->dir, path, sizeof(loc->dir));
	} else {
		char	*tmp;

		tmp = absolutify_path(*argv);
		strlcpy(loc->dir, tmp, sizeof(loc->dir));
		free(tmp);
	}

	if ((loc->dirfd = open(loc->dir, O_RDONLY|O_DIRECTORY)) == -1)
		fatal("can't open %s", loc->dir);

	/* setup tls */

	if ((tlsconf = tls_config_new()) == NULL)
		fatal("tls_config_new"); /* XXX: fatalx */

	/* optionally accept client certs but don't try to verify them */
	tls_config_verify_client_optional(tlsconf);
	tls_config_insecure_noverifycert(tlsconf);

	if ((ctx = tls_server()) == NULL)
		fatal("tls_server failure"); /* XXX: fatalx */

	if (tls_config_set_keypair_file(tlsconf, host->cert, host->key))
		fatal("can't load the keypair (%s, %s)",
		    host->cert, host->key);

	if (tls_configure(ctx, tlsconf) == -1)
		fatal("tls_configure: %s", tls_error(ctx));

	/* start the server */
	signal(SIGPIPE, SIG_IGN);
	setproctitle("%s", loc->dir);
	return serve(hostname, conf.port, loc->dir, ctx);
}
