/*
 * Copyright (c) 2020, 2021, 2022 Omar Polo <op@omarpolo.com>
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

#ifndef GMID_H
#define GMID_H

#include "config.h"

#include <sys/socket.h>
#include <sys/types.h>

#include <arpa/inet.h>
#include <netinet/in.h>

#include <dirent.h>
#include <limits.h>
#include <netdb.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <tls.h>
#include <unistd.h>

#include <openssl/x509.h>

#if HAVE_EVENT2
# include <event2/event.h>
# include <event2/event_compat.h>
# include <event2/event_struct.h>
# include <event2/buffer.h>
# include <event2/buffer_compat.h>
# include <event2/bufferevent.h>
# include <event2/bufferevent_struct.h>
# include <event2/bufferevent_compat.h>
#else
# include <event.h>
#endif

#define VERSION_STR(n)	n " " VERSION
#define GE_STRING	VERSION_STR("ge")
#define GG_STRING	VERSION_STR("gg")
#define GMID_STRING	VERSION_STR("gmid")

#define GMID_VERSION	"gmid/" VERSION

#define GEMINI_URL_LEN (1024+3)	/* URL max len + \r\n + \0 */

#define SUCCESS		20
#define TEMP_REDIRECT	30
#define TEMP_FAILURE	40
#define CGI_ERROR	42
#define PROXY_ERROR	43
#define NOT_FOUND	51
#define PROXY_REFUSED	53
#define BAD_REQUEST	59
#define CLIENT_CERT_REQ	60
#define CERT_NOT_AUTH	61

/* maximum hostname and label length, +1 for the NUL-terminator */
#define DOMAIN_NAME_LEN	(253+1)
#define LABEL_LEN	(63+1)

#define MEDIATYPE_NAMEMAX	128	/* file name extension */
#define MEDIATYPE_TYPEMAX	128	/* length of type/subtype */

#define FCGI_NAME_MAX		511
#define FCGI_VAL_MAX		511

#define FCGI_MAX	32
#define PROC_MAX	16

struct iri {
	char		*schema;
	char		*host;
	char		*port;
	uint16_t	 port_no;
	char		*path;
	char		*query;
	char		*fragment;
};

struct parser {
	char		*iri;
	struct iri	*parsed;
	const char	*err;
};

struct fcgi {
	int		 id;
	char		 path[PATH_MAX];
	char		 port[32];
};
extern struct fcgi fcgi[FCGI_MAX];

TAILQ_HEAD(proxyhead, proxy);
struct proxy {
	char		 match_proto[32];
	char		 match_host[HOST_NAME_MAX + 1];
	char		 match_port[32];

	char		 host[HOST_NAME_MAX + 1];
	char		 port[32];
	char		 sni[HOST_NAME_MAX];
	int		 notls;
	uint32_t	 protocols;
	int		 noverifyname;
	uint8_t		*cert;
	size_t		 certlen;
	uint8_t		*key;
	size_t		 keylen;
	X509_STORE	*reqca;

	TAILQ_ENTRY(proxy) proxies;
};

TAILQ_HEAD(lochead, location);
struct location {
	char		 match[128];
	char		 lang[32];
	char		 default_mime[MEDIATYPE_TYPEMAX];
	char		 index[PATH_MAX];
	int		 auto_index; /* 0 auto, -1 off, 1 on */
	int		 block_code;
	char		 block_fmt[GEMINI_URL_LEN];
	int		 strip;
	X509_STORE	*reqca;
	int		 disable_log;
	int		 fcgi;

	char		 dir[PATH_MAX];
	int		 dirfd;

	TAILQ_ENTRY(location) locations;
};

TAILQ_HEAD(envhead, envlist);
struct envlist {
	char		 name[FCGI_NAME_MAX];
	char		 value[FCGI_VAL_MAX];
	TAILQ_ENTRY(envlist) envs;
};

TAILQ_HEAD(aliashead, alist);
struct alist {
	char		alias[HOST_NAME_MAX + 1];
	TAILQ_ENTRY(alist) aliases;
};

extern TAILQ_HEAD(vhosthead, vhost) hosts;
struct vhost {
	char		 domain[HOST_NAME_MAX + 1];
	char		 cert[PATH_MAX];
	char		 key[PATH_MAX];
	char		 ocsp[PATH_MAX];

	TAILQ_ENTRY(vhost) vhosts;

	/*
	 * the first location rule is always '*' and holds the default
	 * settings for the vhost, then follows the "real" location
	 * rules as specified in the configuration.
	 */
	struct lochead	 locations;

	struct envhead	 params;
	struct aliashead aliases;
	struct proxyhead proxies;
};

struct etm {			/* extension to mime */
	char	 mime[MEDIATYPE_TYPEMAX];
	char	 ext[MEDIATYPE_NAMEMAX];
};

struct mime {
	struct etm	*t;
	size_t		 len;
	size_t		 cap;
};

struct conf {
	/* from command line */
	int		 foreground;
	int		 verbose;
	int		 can_open_sockets;

	/* in the config */
	int		 port;
	int		 ipv6;
	uint32_t	 protos;
	struct mime	 mime;
	char		 chroot[PATH_MAX];
	char		 user[LOGIN_NAME_MAX];
	int		 prefork;
};

extern const char *config_path;
extern struct conf conf;

extern struct imsgbuf logibuf, servibuf[PROC_MAX];

extern int servpipes[PROC_MAX];

typedef void (imsg_handlerfn)(struct imsgbuf*, struct imsg*, size_t);

enum {
	REQUEST_UNDECIDED,
	REQUEST_FILE,
	REQUEST_DIR,
	REQUEST_FCGI,
	REQUEST_PROXY,
	REQUEST_DONE,
};

#define IS_INTERNAL_REQUEST(x) \
	 (x) != REQUEST_FCGI && \
	 (x) != REQUEST_PROXY)

struct client {
	uint32_t	 id;
	struct tls	*ctx;
	char		*req;
	size_t		 reqlen;
	struct iri	 iri;
	char		 domain[DOMAIN_NAME_LEN];

	struct bufferevent *bev;

	int		 type;

	struct bufferevent *cgibev;

	struct proxy	*proxy;
	struct bufferevent *proxybev;
	struct tls	*proxyctx;
	int		 proxyevset;
	struct event	 proxyev;

	char		*header;

	int		 code;
	const char	*meta;
	int		 fd, pfd;
	struct dirent	**dir;
	int		 dirlen, diroff;

	/* big enough to store STATUS + SPACE + META + CRLF */
	char		 sbuf[1029];
	ssize_t		 len, off;

	struct sockaddr_storage	 addr;
	struct vhost	*host;	/* host they're talking to */
	size_t		 loc;	/* location matched */

	SPLAY_ENTRY(client) entry;
};
SPLAY_HEAD(client_tree_id, client);
extern struct client_tree_id clients;

struct connreq {
	char	host[NI_MAXHOST];
	char	port[NI_MAXSERV];
	int	flag;
};

enum {
	FILE_EXISTS,
	FILE_DIRECTORY,
	FILE_MISSING,
};

enum imsg_type {
	IMSG_FCGI_REQ,
	IMSG_FCGI_FD,
	IMSG_CONN_REQ,
	IMSG_CONN_FD,
	IMSG_LOG,
	IMSG_LOG_REQUEST,
	IMSG_LOG_TYPE,
	IMSG_QUIT,
};

/* gmid.c */
char		*data_dir(void);
void		 load_local_cert(struct vhost*, const char*, const char*);
void		 load_vhosts(void);
int		 make_socket(int, int);
void		 setup_tls(void);
void		 init_config(void);
void		 free_config(void);
void		 drop_priv(void);

void		 yyerror(const char*, ...);
void		 parse_conf(const char*);
void		 print_conf(void);
int		 cmdline_symset(char *);

/* log.c */
void		 fatal(const char*, ...)
	__attribute__((format (printf, 1, 2)))
	__attribute__((__noreturn__));

#define LOG_ATTR_FMT __attribute__((format (printf, 2, 3)))
void		 log_err(struct client*, const char*, ...)	LOG_ATTR_FMT;
void		 log_warn(struct client*, const char*, ...)	LOG_ATTR_FMT;
void		 log_notice(struct client*, const char*, ...)	LOG_ATTR_FMT;
void		 log_info(struct client*, const char*, ...)	LOG_ATTR_FMT;
void		 log_debug(struct client*, const char*, ...)	LOG_ATTR_FMT;
void		 log_request(struct client*, char*, size_t);
int		 logger_main(int, struct imsgbuf*);

/* mime.c */
void		 init_mime(struct mime*);
int		 add_mime(struct mime*, const char*, const char*);
int		 load_default_mime(struct mime*);
void		 sort_mime(struct mime *);
const char	*mime(struct vhost*, const char*);
void		 free_mime(struct mime *);

/* server.c */
extern int	shutting_down;
const char	*vhost_lang(struct vhost*, const char*);
const char	*vhost_default_mime(struct vhost*, const char*);
const char	*vhost_index(struct vhost*, const char*);
int		 vhost_auto_index(struct vhost*, const char*);
int		 vhost_block_return(struct vhost*, const char*, int*, const char**);
int		 vhost_fastcgi(struct vhost*, const char*);
int		 vhost_dirfd(struct vhost*, const char*, size_t*);
int		 vhost_strip(struct vhost*, const char*);
X509_STORE	*vhost_require_ca(struct vhost*, const char*);
int		 vhost_disable_log(struct vhost*, const char*);

void		 mark_nonblock(int);
void		 client_write(struct bufferevent *, void *);
void		 start_reply(struct client*, int, const char*);
void		 client_close(struct client *);
struct client	*client_by_id(int);
void		 loop(struct tls*, int, int, struct imsgbuf*);

int		 client_tree_cmp(struct client *, struct client *);
SPLAY_PROTOTYPE(client_tree_id, client, entry, client_tree_cmp);

/* dirs.c */
int		 scandir_fd(int, struct dirent***, int(*)(const struct dirent*),
		    int(*)(const struct dirent**, const struct dirent**));
int		 select_non_dot(const struct dirent*);
int		 select_non_dotdot(const struct dirent*);

/* fcgi.c */
void		 fcgi_read(struct bufferevent *, void *);
void		 fcgi_write(struct bufferevent *, void *);
void		 fcgi_error(struct bufferevent *, short, void *);
void		 fcgi_req(struct client *);

/* sandbox.c */
void		 sandbox_server_process(int);
void		 sandbox_logger_process(void);

/* utf8.c */
int		 valid_multibyte_utf8(struct parser*);
char		*utf8_nth(char*, size_t);

/* iri.c */
int		 parse_iri(char*, struct iri*, const char**);
int		 serialize_iri(struct iri*, char*, size_t);
int		 encode_path(char *, size_t, const char *);
char		*pct_decode_str(char *);

/* proxy.c */
int		 proxy_init(struct client *);

/* puny.c */
int		 puny_decode(const char*, char*, size_t, const char**);

/* utils.c */
void		 block_signals(void);
void		 unblock_signals(void);
int		 starts_with(const char*, const char*);
int		 ends_with(const char*, const char*);
ssize_t		 filesize(int);
char		*absolutify_path(const char*);
char		*xstrdup(const char*);
void		*xcalloc(size_t, size_t);
void		 gen_certificate(const char*, const char*, const char*);
X509_STORE	*load_ca(const char*);
int		 validate_against_ca(X509_STORE*, const uint8_t*, size_t);
void		 dispatch_imsg(struct imsgbuf*, imsg_handlerfn**, size_t);

#endif
