%{

/*
 * Copyright (c) 2021, 2022 Omar Polo <op@omarpolo.com>
 * Copyright (c) 2018 Florian Obser <florian@openbsd.org>
 * Copyright (c) 2004, 2005 Esben Norby <norby@openbsd.org>
 * Copyright (c) 2004 Ryan McBride <mcbride@openbsd.org>
 * Copyright (c) 2002, 2003, 2004 Henning Brauer <henning@openbsd.org>
 * Copyright (c) 2001 Markus Friedl.  All rights reserved.
 * Copyright (c) 2001 Daniel Hartmeier.  All rights reserved.
 * Copyright (c) 2001 Theo de Raadt.  All rights reserved.
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

#include <ctype.h>
#include <errno.h>
#include <netdb.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

TAILQ_HEAD(files, file)		 files = TAILQ_HEAD_INITIALIZER(files);
static struct file {
	TAILQ_ENTRY(file)	 entry;
	FILE			*stream;
	char			*name;
	size_t	 		 ungetpos;
	size_t			 ungetsize;
	u_char			*ungetbuf;
	int			 eof_reached;
	int			 lineno;
	int			 errors;
} *file, *topfile;

struct file	*pushfile(const char *, int);
int		 popfile(void);
int		 yyparse(void);
int		 yylex(void);
void		 yyerror(const char *, ...)
    __attribute__((__format__ (printf, 1, 2)))
    __attribute__((__nonnull__ (1)));
void		 yywarn(const char *, ...)
    __attribute__((__format__ (printf, 1, 2)))
    __attribute__((__nonnull__ (1)));
int		 kw_cmp(const void *, const void *);
int		 lookup(char *);
int		 igetc(void);
int		 lgetc(int);
void		 lungetc(int);
int		 findeol(void);

/*
 * #define YYDEBUG 1
 * int yydebug = 1;
 */

TAILQ_HEAD(symhead, sym) symhead = TAILQ_HEAD_INITIALIZER(symhead);
struct sym {
	TAILQ_ENTRY(sym)	 entry;
	int			 used;
	int			 persist;
	char			*name;
	char			*val;
};

int	 symset(const char *, const char *, int);
char	*symget(const char *);

struct vhost	*new_vhost(void);
struct location	*new_location(void);
struct proxy	*new_proxy(void);
char		*ensure_absolute_path(char*);
int		 check_block_code(int);
char		*check_block_fmt(char*);
int		 check_strip_no(int);
int		 check_port_num(int);
int		 check_prefork_num(int);
void		 advance_loc(void);
void		 advance_proxy(void);
void		 parsehp(char *, char **, const char **, const char *);
int		 fastcgi_conf(const char *, const char *);
void		 add_param(char *, char *);
int		 getservice(const char *);

static struct vhost		*host;
static struct location		*loc;
static struct proxy		*proxy;
static char			*current_media;
static int			 errors;

typedef struct {
	union {
		char	*string;
		int	 number;
	} v;
	int lineno;
} YYSTYPE;

%}

/* for bison: */
/* %define parse.error verbose */

%token	ALIAS AUTO
%token	BLOCK
%token	CA CERT CHROOT CLIENT
%token	DEFAULT
%token	FASTCGI FOR_HOST
%token	INCLUDE INDEX IPV6
%token	KEY
%token	LANG LOCATION LOG
%token	OCSP OFF ON
%token	PARAM PORT PREFORK PROTO PROTOCOLS PROXY
%token	RELAY_TO REQUIRE RETURN ROOT
%token	SERVER SNI STRIP
%token	TCP TOEXT TYPE TYPES
%token	USE_TLS USER
%token	VERIFYNAME

%token	ERROR

%token	<v.string>	STRING
%token	<v.number>	NUM

%type	<v.number>	bool proxy_port
%type	<v.string>	string numberstring

%%

conf		: /* empty */
		| conf include '\n'
		| conf '\n'
		| conf varset '\n'
		| conf option '\n'
		| conf vhost '\n'
		| conf types '\n'
		| conf error '\n'		{ file->errors++; }
		;

include		: INCLUDE STRING		{
			struct file	*nfile;

			if ((nfile = pushfile($2, 0)) == NULL) {
				yyerror("failed to include file %s", $2);
				free($2);
				YYERROR;
			}
			free($2);

			file = nfile;
			lungetc('\n');
		}
		;

bool		: ON	{ $$ = 1; }
		| OFF	{ $$ = 0; }
		;

string		: string STRING	{
			if (asprintf(&$$, "%s%s", $1, $2) == -1) {
				free($1);
				free($2);
				yyerror("string: asprintf: %s", strerror(errno));
				YYERROR;
			}
			free($1);
			free($2);
		}
		| STRING
		;

numberstring	: NUM {
			char *s;
			if (asprintf(&s, "%d", $1) == -1) {
				yyerror("asprintf: number");
				YYERROR;
			}
			$$ = s;
		}
		| STRING
		;

varset		: STRING '=' string		{
			char *s = $1;
			while (*s++) {
				if (isspace((unsigned char)*s)) {
					yyerror("macro name cannot contain "
					    "whitespaces");
					free($1);
					free($3);
					YYERROR;
				}
			}
			symset($1, $3, 0);
			free($1);
			free($3);
		}
		;

option		: CHROOT string	{
			if (strlcpy(conf.chroot, $2, sizeof(conf.chroot)) >=
			    sizeof(conf.chroot))
				yyerror("chroot path too long");
			free($2);
		}
		| IPV6 bool		{ conf.ipv6 = $2; }
		| PORT NUM		{ conf.port = check_port_num($2); }
		| PREFORK NUM		{ conf.prefork = check_prefork_num($2); }
		| PROTOCOLS string {
			if (tls_config_parse_protocols(&conf.protos, $2) == -1)
				yyerror("invalid protocols string \"%s\"", $2);
			free($2);
		}
		| USER string {
			if (strlcpy(conf.user, $2, sizeof(conf.user)) >=
			    sizeof(conf.user))
				yyerror("user name too long");
			free($2);
		}
		;

vhost		: SERVER string {
			host = new_vhost();
			TAILQ_INSERT_HEAD(&hosts, host, vhosts);

			loc = new_location();
			TAILQ_INSERT_HEAD(&host->locations, loc, locations);

			TAILQ_INIT(&host->proxies);

			(void) strlcpy(loc->match, "*", sizeof(loc->match));
			(void) strlcpy(host->domain, $2, sizeof(host->domain));

			if (strstr($2, "xn--") != NULL) {
				yywarn("\"%s\" looks like punycode: you "
				    "should use the decoded hostname", $2);
			}

			free($2);
		} '{' optnl servbody '}' {
			if (*host->cert == '\0' || *host->key == '\0')
				yyerror("invalid vhost definition: %s", $2);
		}
		| error '}'		{ yyerror("bad server directive"); }
		;

servbody	: /* empty */
		| servbody servopt optnl
		| servbody location optnl
		| servbody proxy optnl
		;

servopt		: ALIAS string {
			struct alist *a;

			a = xcalloc(1, sizeof(*a));
			(void) strlcpy(a->alias, $2, sizeof(a->alias));
			free($2);
			TAILQ_INSERT_TAIL(&host->aliases, a, aliases);
		}
		| CERT string		{
			ensure_absolute_path($2);
			(void) strlcpy(host->cert, $2, sizeof(host->cert));
			free($2);
		}
		| KEY string		{
			ensure_absolute_path($2);
			(void) strlcpy(host->key, $2, sizeof(host->key));
			free($2);
		}
		| OCSP string		{
			ensure_absolute_path($2);
			(void) strlcpy(host->ocsp, $2, sizeof(host->ocsp));
			free($2);
		}
		| PARAM string '=' string {
			add_param($2, $4);
		}
		| locopt
		;

proxy		: PROXY { advance_proxy(); }
		  proxy_matches '{' optnl proxy_opts '}' {
			if (*proxy->host == '\0')
				yyerror("invalid proxy block: missing `relay-to' option");

			if ((proxy->cert == NULL && proxy->key != NULL) ||
			    (proxy->cert != NULL && proxy->key == NULL))
				yyerror("invalid proxy block: missing cert or key");
		}
		;

proxy_matches	: /* empty */
		| proxy_matches proxy_match
		;

proxy_port	: /* empty */	{ $$ = 1965; }
		| PORT STRING {
			if (($$ = getservice($2)) == -1)
				yyerror("invalid port number %s", $2);
			free($2);
		}
		| PORT NUM	{ $$ = $2; }
		;

proxy_match	: PROTO string {
			(void) strlcpy(proxy->match_proto, $2, sizeof(proxy->match_proto));
			free($2);
		}
		| FOR_HOST string proxy_port {
			(void) strlcpy(proxy->match_host, $2, sizeof(proxy->match_host));
			(void) snprintf(proxy->match_port, sizeof(proxy->match_port),
			    "%d", $3);
			free($2);
		}
		;

proxy_opts	: /* empty */
		| proxy_opts proxy_opt optnl
		;

proxy_opt	: CERT string {
			tls_unload_file(proxy->cert, proxy->certlen);
			ensure_absolute_path($2);
			proxy->cert = tls_load_file($2, &proxy->certlen, NULL);
			if (proxy->cert == NULL)
				yyerror("can't load cert %s", $2);
			free($2);
		}
		| KEY string {
			tls_unload_file(proxy->key, proxy->keylen);
			ensure_absolute_path($2);
			proxy->key = tls_load_file($2, &proxy->keylen, NULL);
			if (proxy->key == NULL)
				yyerror("can't load key %s", $2);
			free($2);
		}
		| PROTOCOLS string {
			if (tls_config_parse_protocols(&proxy->protocols, $2) == -1)
				yyerror("invalid protocols string \"%s\"", $2);
			free($2);
		}
		| RELAY_TO string proxy_port {
			(void) strlcpy(proxy->host, $2, sizeof(proxy->host));
			(void) snprintf(proxy->port, sizeof(proxy->port),
			    "%d", $3);
			free($2);
		}
		| REQUIRE CLIENT CA string {
			ensure_absolute_path($4);
			if ((proxy->reqca = load_ca($4)) == NULL)
				yyerror("couldn't load ca cert: %s", $4);
			free($4);
		}
		| SNI string {
			(void) strlcpy(proxy->sni, $2, sizeof(proxy->sni));
			free($2);
		}
		| USE_TLS bool {
			proxy->notls = !$2;
		}
		| VERIFYNAME bool {
			proxy->noverifyname = !$2;
		}
		;

location	: LOCATION { advance_loc(); } string '{' optnl locopts '}' {
			/* drop the starting '/' if any */
			if (*$3 == '/')
				memmove($3, $3+1, strlen($3));
			(void) strlcpy(loc->match, $3, sizeof(loc->match));
			free($3);
		}
		| error '}'
		;

locopts		: /* empty */
		| locopts locopt optnl
		;

locopt		: AUTO INDEX bool	{ loc->auto_index = $3 ? 1 : -1; }
		| BLOCK RETURN NUM string {
			check_block_fmt($4);
			(void) strlcpy(loc->block_fmt, $4, sizeof(loc->block_fmt));
			loc->block_code = check_block_code($3);
			free($4);
		}
		| BLOCK RETURN NUM {
			(void) strlcpy(loc->block_fmt, "temporary failure",
			    sizeof(loc->block_fmt));
			loc->block_code = check_block_code($3);
			if ($3 >= 30 && $3 < 40)
				yyerror("missing `meta' for block return %d", $3);
		}
		| BLOCK {
			(void) strlcpy(loc->block_fmt, "temporary failure",
			    sizeof(loc->block_fmt));
			loc->block_code = 40;
		}
		| DEFAULT TYPE string {
			(void) strlcpy(loc->default_mime, $3,
			    sizeof(loc->default_mime));
			free($3);
		}
		| FASTCGI fastcgi
		| INDEX string {
			(void) strlcpy(loc->index, $2, sizeof(loc->index));
			free($2);
		}
		| LANG string {
			(void) strlcpy(loc->lang, $2,
			    sizeof(loc->lang));
			free($2);
		}
		| LOG bool	{ loc->disable_log = !$2; }
		| REQUIRE CLIENT CA string {
			ensure_absolute_path($4);
			if ((loc->reqca = load_ca($4)) == NULL)
				yyerror("couldn't load ca cert: %s", $4);
			free($4);
		}
		| ROOT string		{
			(void) strlcpy(loc->dir, $2, sizeof(loc->dir));
			free($2);
		}
		| STRIP NUM		{ loc->strip = check_strip_no($2); }
		;

fastcgi		: string {
			loc->fcgi = fastcgi_conf($1, NULL);
			free($1);
		}
		| TCP string PORT NUM {
			char *c;
			if (asprintf(&c, "%d", $4) == -1)
				err(1, "asprintf");
			loc->fcgi = fastcgi_conf($2, c);
			free($2);
		}
		| TCP string {
			loc->fcgi = fastcgi_conf($2, "9000");
			free($2);
		}
		| TCP string PORT string {
			loc->fcgi = fastcgi_conf($2, $4);
			free($2);
			free($4);
		}
		;

types		: TYPES '{' optnl mediaopts_l '}' ;

mediaopts_l	: mediaopts_l mediaoptsl nl
		| mediaoptsl nl
		;

mediaoptsl	: STRING {
			free(current_media);
			current_media = $1;
		} medianames_l optsemicolon
		| include
		;

medianames_l	: medianames_l medianamesl
		| medianamesl
		;

medianamesl	: numberstring {
			if (add_mime(&conf.mime, current_media, $1) == -1)
				err(1, "add_mime");
			free($1);
		}
		;

nl		: '\n' optnl
		;

optnl		: '\n' optnl		/* zero or more newlines */
		| ';' optnl		/* semicolons too */
		| /*empty*/
		;

optsemicolon	: ';'
		|
		;

%%

static const struct keyword {
	const char *word;
	int token;
} keywords[] = {
	/* these MUST be sorted */
	{"alias", ALIAS},
	{"auto", AUTO},
	{"block", BLOCK},
	{"ca", CA},
	{"cert", CERT},
	{"chroot", CHROOT},
	{"client", CLIENT},
	{"default", DEFAULT},
	{"fastcgi", FASTCGI},
	{"for-host", FOR_HOST},
	{"include", INCLUDE},
	{"index", INDEX},
	{"ipv6", IPV6},
	{"key", KEY},
	{"lang", LANG},
	{"location", LOCATION},
	{"log", LOG},
	{"ocsp", OCSP},
	{"off", OFF},
	{"on", ON},
	{"param", PARAM},
	{"port", PORT},
	{"prefork", PREFORK},
	{"proto", PROTO},
	{"protocols", PROTOCOLS},
	{"proxy", PROXY},
	{"relay-to", RELAY_TO},
	{"require", REQUIRE},
	{"return", RETURN},
	{"root", ROOT},
	{"server", SERVER},
	{"sni", SNI},
	{"strip", STRIP},
	{"tcp", TCP},
	{"to-ext", TOEXT},
	{"type", TYPE},
	{"types", TYPES},
	{"use-tls", USE_TLS},
	{"user", USER},
	{"verifyname", VERIFYNAME},
};

void
yyerror(const char *msg, ...)
{
	va_list ap;

	file->errors++;

	va_start(ap, msg);
	fprintf(stderr, "%s:%d error: ", config_path, yylval.lineno);
	vfprintf(stderr, msg, ap);
	fprintf(stderr, "\n");
	va_end(ap);
}

void
yywarn(const char *msg, ...)
{
	va_list ap;

	va_start(ap, msg);
	fprintf(stderr, "%s:%d warning: ", config_path, yylval.lineno);
	vfprintf(stderr, msg, ap);
	fprintf(stderr, "\n");
	va_end(ap);
}

int
kw_cmp(const void *k, const void *e)
{
	return strcmp(k, ((struct keyword *)e)->word);
}

int
lookup(char *s)
{
	const struct keyword	*p;

	p = bsearch(s, keywords, sizeof(keywords)/sizeof(keywords[0]),
	    sizeof(keywords[0]), kw_cmp);

	if (p)
		return p->token;
	else
		return STRING;
}

#define START_EXPAND	1
#define DONE_EXPAND	2

static int	expanding;

int
igetc(void)
{
	int	c;

	while (1) {
		if (file->ungetpos > 0)
			c = file->ungetbuf[--file->ungetpos];
		else
			c = getc(file->stream);

		if (c == START_EXPAND)
			expanding = 1;
		else if (c == DONE_EXPAND)
			expanding = 0;
		else
			break;
	}
	return c;
}

int
lgetc(int quotec)
{
	int		c, next;

	if (quotec) {
		if ((c = igetc()) == EOF) {
			yyerror("reached end of file while parsing "
			    "quoted string");
			if (file == topfile || popfile() == EOF)
				return EOF;
			return quotec;
		}
		return c;
	}

	while ((c = igetc()) == '\\') {
		next = igetc();
		if (next != '\n') {
			c = next;
			break;
		}
		yylval.lineno = file->lineno;
		file->lineno++;
	}

	if (c == EOF) {
		/*
		 * Fake EOL when hit EOF for the first time. This gets line
		 * count right if last line in included file is syntactically
		 * invalid and has no newline.
		 */
		if (file->eof_reached == 0) {
			file->eof_reached = 1;
			return '\n';
		}
		while (c == EOF) {
			if (file == topfile || popfile() == EOF)
				return EOF;
			c = igetc();
		}
	}
	return c;
}

void
lungetc(int c)
{
	if (c == EOF)
		return;

	if (file->ungetpos >= file->ungetsize) {
		void *p = reallocarray(file->ungetbuf, file->ungetsize, 2);
		if (p == NULL)
			err(1, "lungetc");
		file->ungetbuf = p;
		file->ungetsize *= 2;
	}
	file->ungetbuf[file->ungetpos++] = c;
}

int
findeol(void)
{
	int	c;

	/* Skip to either EOF or the first real EOL. */
	while (1) {
		c = lgetc(0);
		if (c == '\n') {
			file->lineno++;
			break;
		}
		if (c == EOF)
			break;
	}
	return ERROR;
}

int
yylex(void)
{
	char	 buf[8096];
	char	*p, *val;
	int	 quotec, next, c;
	int	 token;

top:
	p = buf;
	while ((c = lgetc(0)) == ' ' || c == '\t')
		; /* nothing */

	yylval.lineno = file->lineno;
	if (c == '#')
		while ((c = lgetc(0)) != '\n' && c != EOF)
			; /* nothing */
	if (c == '$' && !expanding) {
		while (1) {
			if ((c = lgetc(0)) == EOF)
				return 0;
			if (p + 1 >= buf + sizeof(buf) -1) {
				yyerror("string too long");
				return findeol();
			}
			if (isalnum(c) || c == '_') {
				*p++ = c;
				continue;
			}
			*p = '\0';
			lungetc(c);
			break;
		}
		val = symget(buf);
		if (val == NULL) {
			yyerror("macro `%s' not defined", buf);
			return findeol();
		}
		yylval.v.string = xstrdup(val);
		return STRING;
	}
	if (c == '@' && !expanding) {
		while (1) {
			if ((c = lgetc(0)) == EOF)
				return 0;

			if (p + 1 >= buf + sizeof(buf) - 1) {
				yyerror("string too long");
				return findeol();
			}
			if (isalnum(c) || c == '_') {
				*p++ = c;
				continue;
			}
			*p = '\0';
			lungetc(c);
			break;
		}
		val = symget(buf);
		if (val == NULL) {
			yyerror("macro '%s' not defined", buf);
			return findeol();
		}
		p = val + strlen(val) - 1;
		lungetc(DONE_EXPAND);
		while (p >= val) {
			lungetc(*p);
			p--;
		}
		lungetc(START_EXPAND);
		goto top;
	}

	switch (c) {
	case '\'':
	case '"':
		quotec = c;
		while (1) {
			if ((c = lgetc(quotec)) == EOF)
				return 0;
			if (c == '\n') {
				file->lineno++;
				continue;
			} else if (c == '\\') {
				if ((next = lgetc(quotec)) == EOF)
					return (0);
				if (next == quotec || next == ' ' ||
				    next == '\t')
					c = next;
				else if (next == '\n') {
					file->lineno++;
					continue;
				} else
					lungetc(next);
			} else if (c == quotec) {
				*p = '\0';
				break;
			} else if (c == '\0') {
				yyerror("invalid syntax");
				return findeol();
			}
			if (p + 1 >= buf + sizeof(buf) - 1) {
				yyerror("string too long");
				return findeol();
			}
			*p++ = c;
		}
		yylval.v.string = strdup(buf);
		if (yylval.v.string == NULL)
			err(1, "yylex: strdup");
		return STRING;
	}

#define allowed_to_end_number(x) \
	(isspace(x) || x == ')' || x ==',' || x == '/' || x == '}' || x == '=')

	if (c == '-' || isdigit(c)) {
		do {
			*p++ = c;
			if ((size_t)(p-buf) >= sizeof(buf)) {
				yyerror("string too long");
				return findeol();
			}
		} while ((c = lgetc(0)) != EOF && isdigit(c));
		lungetc(c);
		if (p == buf + 1 && buf[0] == '-')
			goto nodigits;
		if (c == EOF || allowed_to_end_number(c)) {
			const char *errstr = NULL;

			*p = '\0';
			yylval.v.number = strtonum(buf, LLONG_MIN,
			    LLONG_MAX, &errstr);
			if (errstr) {
				yyerror("\"%s\" invalid number: %s",
				    buf, errstr);
				return findeol();
			}
			return NUM;
		} else {
nodigits:
			while (p > buf + 1)
				lungetc(*--p);
			c = *--p;
			if (c == '-')
				return c;
		}
	}

#define allowed_in_string(x) \
	(isalnum(x) || (ispunct(x) && x != '(' && x != ')' && \
	x != '{' && x != '}' && \
	x != '!' && x != '=' && x != '#' && \
	x != ',' && x != ';'))

	if (isalnum(c) || c == ':' || c == '_') {
		do {
			*p++ = c;
			if ((size_t)(p-buf) >= sizeof(buf)) {
				yyerror("string too long");
				return findeol();
			}
		} while ((c = lgetc(0)) != EOF && (allowed_in_string(c)));
		lungetc(c);
		*p = '\0';
		if ((token = lookup(buf)) == STRING)
			yylval.v.string = xstrdup(buf);
		return token;
	}
	if (c == '\n') {
		yylval.lineno = file->lineno;
		file->lineno++;
	}
	if (c == EOF)
		return 0;
	return c;
}

struct file *
pushfile(const char *name, int secret)
{
	struct file	*nfile;

	nfile = xcalloc(1, sizeof(*nfile));
	nfile->name = xstrdup(name);
	if ((nfile->stream = fopen(nfile->name, "r")) == NULL) {
		log_warn(NULL, "can't open %s: %s", nfile->name,
		    strerror(errno));
		free(nfile->name);
		free(nfile);
		return NULL;
	}
	nfile->lineno = TAILQ_EMPTY(&files) ? 1 : 0;
	nfile->ungetsize = 16;
	nfile->ungetbuf = xcalloc(1, nfile->ungetsize);
	TAILQ_INSERT_TAIL(&files, nfile, entry);
	return nfile;
}

int
popfile(void)
{
	struct file	*prev;

	if ((prev = TAILQ_PREV(file, files, entry)) != NULL)
		prev->errors += file->errors;

	TAILQ_REMOVE(&files, file, entry);
	fclose(file->stream);
	free(file->name);
	free(file->ungetbuf);
	free(file);
	file = prev;
	return file ? 0 : EOF;
}

void
parse_conf(const char *filename)
{
	struct sym		*sym, *next;

	file = pushfile(filename, 0);
	if (file == NULL)
		exit(1);
	topfile = file;

	yyparse();
	errors = file->errors;
	popfile();

	/* Free macros and check which have not been used. */
	TAILQ_FOREACH_SAFE(sym, &symhead, entry, next) {
		/* TODO: warn if !sym->used */
		if (!sym->persist) {
			free(sym->name);
			free(sym->val);
			TAILQ_REMOVE(&symhead, sym, entry);
			free(sym);
		}
	}

	if (errors)
		exit(1);
}

void
print_conf(void)
{
	struct vhost	*h;
	/* struct location	*l; */
	/* struct envlist	*e; */
	/* struct alist	*a; */

	if (*conf.chroot != '\0')
		printf("chroot \"%s\"\n", conf.chroot);
	printf("ipv6 %s\n", conf.ipv6 ? "on" : "off");
	/* XXX: defined mimes? */
	printf("port %d\n", conf.port);
	printf("prefork %d\n", conf.prefork);
	/* XXX: protocols? */
	if (*conf.user != '\0')
		printf("user \"%s\"\n", conf.user);

	TAILQ_FOREACH(h, &hosts, vhosts) {
		printf("\nserver \"%s\" {\n", h->domain);
		printf("	cert \"%s\"\n", h->cert);
		printf("	key \"%s\"\n", h->key);
		/* TODO: print locations... */
		printf("}\n");
	}
}

int
symset(const char *name, const char *val, int persist)
{
	struct sym *sym;

	TAILQ_FOREACH(sym, &symhead, entry) {
		if (!strcmp(name, sym->name))
			break;
	}

	if (sym != NULL) {
		if (sym->persist)
			return 0;
		else {
			free(sym->name);
			free(sym->val);
			TAILQ_REMOVE(&symhead, sym, entry);
			free(sym);
		}
	}

	sym = xcalloc(1, sizeof(*sym));
	sym->name = xstrdup(name);
	sym->val = xstrdup(val);
	sym->used = 0;
	sym->persist = persist;

	TAILQ_INSERT_TAIL(&symhead, sym, entry);
	return 0;
}

int
cmdline_symset(char *s)
{
	char	*sym, *val;
	int	 ret;

	if ((val = strrchr(s, '=')) == NULL)
		return -1;
	sym = xcalloc(1, val - s + 1);
	memcpy(sym, s, val - s);
	ret = symset(sym, val + 1, 1);
	free(sym);
	return ret;
}

char *
symget(const char *nam)
{
	struct sym	*sym;

	TAILQ_FOREACH(sym, &symhead, entry) {
		if (strcmp(nam, sym->name) == 0) {
			sym->used = 1;
			return sym->val;
		}
	}
	return NULL;
}

struct vhost *
new_vhost(void)
{
	struct vhost *h;

	h = xcalloc(1, sizeof(*h));
	TAILQ_INIT(&h->locations);
	TAILQ_INIT(&h->params);
	TAILQ_INIT(&h->aliases);
	TAILQ_INIT(&h->proxies);
	return h;
}

struct location *
new_location(void)
{
	struct location *l;

	l = xcalloc(1, sizeof(*l));
	l->dirfd = -1;
	l->fcgi = -1;
	return l;
}

struct proxy *
new_proxy(void)
{
	struct proxy *p;

	conf.can_open_sockets = 1;

	p = xcalloc(1, sizeof(*p));
	p->protocols = TLS_PROTOCOLS_DEFAULT;
	return p;
}

char *
ensure_absolute_path(char *path)
{
	if (path == NULL || *path != '/')
		yyerror("not an absolute path: %s", path);
	return path;
}

int
check_block_code(int n)
{
	if (n < 10 || n >= 70 || (n >= 20 && n <= 29))
		yyerror("invalid block code %d", n);
	return n;
}

char *
check_block_fmt(char *fmt)
{
	char *s;

	for (s = fmt; *s; ++s) {
		if (*s != '%')
			continue;
		switch (*++s) {
		case '%':
		case 'p':
		case 'q':
		case 'P':
		case 'N':
			break;
		default:
			yyerror("invalid format specifier %%%c", *s);
		}
	}

	return fmt;
}

int
check_strip_no(int n)
{
	if (n <= 0)
		yyerror("invalid strip number %d", n);
	return n;
}

int
check_port_num(int n)
{
	if (n <= 0 || n >= UINT16_MAX)
		yyerror("port number is %s: %d",
		    n <= 0 ? "too small" : "too large",
		    n);
	return n;
}

int
check_prefork_num(int n)
{
	if (n <= 0 || n >= PROC_MAX)
		yyerror("invalid prefork number %d", n);
	return n;
}

void
advance_loc(void)
{
	loc = new_location();
	TAILQ_INSERT_TAIL(&host->locations, loc, locations);
}

void
advance_proxy(void)
{
	proxy = new_proxy();
	TAILQ_INSERT_TAIL(&host->proxies, proxy, proxies);
}

void
parsehp(char *str, char **host, const char **port, const char *def)
{
	char		*at;
	const char	*errstr;

	*host = str;

	if ((at = strchr(str, ':')) != NULL) {
		*at++ = '\0';
		*port = at;
	} else
		*port = def;

	strtonum(*port, 1, UINT16_MAX, &errstr);
	if (errstr != NULL)
		yyerror("port is %s: %s", errstr, *port);
}

int
fastcgi_conf(const char *path, const char *port)
{
	struct fcgi	*f;
	int		i;

	conf.can_open_sockets = 1;

	for (i = 0; i < FCGI_MAX; ++i) {
		f = &fcgi[i];

		if (*f->path == '\0') {
			f->id = i;
			(void) strlcpy(f->path, path, sizeof(f->path));
			if (port != NULL)
				(void) strlcpy(f->port, port, sizeof(f->port));
			return i;
		}

		if (!strcmp(f->path, path) &&
		    ((port == NULL && *f->port == '\0') ||
		     !strcmp(f->port, port)))
			return i;
	}

	yyerror("too much `fastcgi' rules defined.");
	return -1;
}

void
add_param(char *name, char *val)
{
	struct envlist *e;
	struct envhead *h = &host->params;

	e = xcalloc(1, sizeof(*e));
	(void) strlcpy(e->name, name, sizeof(e->name));
	(void) strlcpy(e->value, val, sizeof(e->value));
	TAILQ_INSERT_TAIL(h, e, envs);
}

int
getservice(const char *n)
{
	struct servent	*s;
	const char	*errstr;
	long long	 llval;

	llval = strtonum(n, 0, UINT16_MAX, &errstr);
	if (errstr) {
		s = getservbyname(n, "tcp");
		if (s == NULL)
			s = getservbyname(n, "udp");
		if (s == NULL)
			return (-1);
		return (ntohs(s->s_port));
	}

	return ((unsigned short)llval);
}
