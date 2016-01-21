#!/bin/sh -e

_name="$(basename $0)"
_version="1.1"
_host="$(hostname -f)"

rotate=7
rotate_file="$HOME/.mydbs"

info() { echo -e "$_name: $@"; }
info2() { echo -en "$_name: $@"; }
err() {	echo "$_name: $@" >&2; }
info2log() { _data="$(date +%d/%m/%Y" "%H:%M:%S)"; echo "$_data: $_name: $1" >>$sql_log; }

usage()
{
	cat << EOF
$_name: mysql database backup script

Usage: $_name [OPTIONS] ...

         -h               Show this help
         -v               Show version number
         -l               Use this rotate level
                          (default: 7)
         -d               Use this directory to backups the databases
                          (default: /mnt/backup)
         -u               Use this username
                          (default: root)
         -p               Use this password
                          (default: none)
         -s               Use this socket
                          (default: none)

Example:
       $_name -d /mnt/nfs_backup -u root -p mypwd -s /var/lib/mysql/mysql.sock
   or
       $_name

EOF
}

set_defaults()
{
	[ -n "$sql_cmd" ] || sql_cmd="$(which mysql 2>/dev/null || echo mysql)"
	[ -n "$sql_dump_cmd" ] || sql_dump_cmd="$(which mysqldump 2>/dev/null || echo mysqldump)"
	[ -n "$sql_user" ] || sql_user="root"
	[ -n "$sql_pass" ] || sql_pass=""
	[ -n "$sql_socket" ] || sql_socket=""
	[ -n "$sql_backup" ] || sql_backup="/mnt/backup"
	[ -n "$sql_log" ] || sql_log="/var/log/mydbs.log"
	[ -n "$sql_ext" ] || sql_ext="sql"

	sql_def_conf="/tmp/.my.$$.cnf"
}

create_conf()
{
	touch $sql_def_conf 2>/dev/null || return 1
	chmod 0600 $sql_def_conf 2>/dev/null || return 1
	cat << EOF > $sql_def_conf
[client]
user=$sql_user
password=$sql_pass
socket=$sql_socket
EOF
	return 0
}

destroy_conf()
{
 	[ -e "$sql_def_conf" ] && rm -f $sql_def_conf 2>/dev/null
}

sql_query()
{
	local query="$1"
	local db="$2"
	local opts="--defaults-file="$sql_def_conf""

	[ -n "$query" ] || return 1
	[ -n "$db" ] && opts="$opts $db -Bse" || opts="$opts -Bse"

	$sql_cmd $opts "$query" 2>/dev/null || return 1
}

check_sql()
{
	if ! sql_query "STATUS;" >/dev/null 2>&1; then
		err "unable to connect to mysql server."
		destroy_conf
		exit 1
	fi
}

get_sql_db()
{
	local query_db="SELECT DISTINCT TABLE_SCHEMA FROM information_schema.TABLES \
	WHERE TABLE_SCHEMA NOT IN ('information_schema','performance_schema');"
	sql_query "$query_db"
}

get_sql_db_count()
{
	local query_db="SELECT COUNT(DISTINCT TABLE_SCHEMA) FROM information_schema.TABLES \
	WHERE TABLE_SCHEMA NOT IN ('information_schema','performance_schema');"
	sql_query "$query_db"
}

get_sql_version()
{
	local query_db="SELECT VERSION();"
	local version="$(sql_query "$query_db")"
	echo $version
}

run_dump()
{
	local opts="--defaults-file="$sql_def_conf""
	local db="$1"
	local db_file="$2"

	$sql_dump_cmd $opts $db > $db_file 2>/dev/null
	return $?
}

run_gzip()
{
	local file="$1"
	local gzfile="${file}.gz"

	gzip -c $file > $gzfile 2>/dev/null
	return $?
}

init_rotate()
{
	local _cur=

        if [ -r "$rotate_file" ]; then
                read _cur < $rotate_file 2>/dev/null
		[ -z $_cur ] && _cur=1
	else
		_cur=1
		rotate_cur=$_cur
		echo 1 > $rotate_file 2>/dev/null
	fi

        if [ $rotate -gt $_cur ]; then
		rotate_cur=$_cur
		_cur=$(($_cur + 1))
                echo $_cur > $rotate_file 2>/dev/null
        elif [ $rotate -eq $_cur ]; then
		rotate_cur=$_cur
		_cur=1
                echo 1 > $rotate_file 2>/dev/null
	elif [ $roate_max -lt $_cur ]; then
		rotate_cur=1
		_cur=1
		echo $_cur > $rotate_file 2>/dev/null
	fi
}

init_logfile()
{
	[ -r "$sql_log" ] && rm -f "$sql_log" >/dev/null 2>&1
	info "-- running mysql version $(get_sql_version) on $_host"
	info2log "-- running mysql version $(get_sql_version) on $_host"
	info "-- running backup at rotate level $rotate_cur out of $rotate"
	info2log "-- running backup at rotate level $rotate_cur out of $rotate"
	info "-- backup directory: $sql_backup"
	info2log "-- backup directory: $sql_backup"
	info "-------------------------------------------------------------"
	info2log "-------------------------------------------------------------a"	
}

elapsed_time()
{
	diff_timer="$((${_end} - ${_start}))"
	timer="$(date -u -d @${diff_timer} +'%-M minutes %-S seconds')"
	info "-- backup finished in $timer"
	info2log "-- backup finished in $timer"
}

while getopts "hvl:d:u:p:s:" opt; do
	case "$opt" in
		h)
		  usage
		  exit 0
		;;
		v)
		  echo "$_name $_version"
		  exit 0
		;;
		l)
		  rotate="${OPTARG}"
		;;
		d)
		  sql_backup="${OPTARG}"
		;;
		u)
		  sql_user="${OPTARG}"
		;;
		p)
		  sql_pass="${OPTARG}"
		;;
		s)
		  sql_socket="${OPTARG}"
		;;
		\?)
		  exit 1
		;;
	esac
done

set_defaults 

if [ ! -x "$sql_cmd" ]; then
	err "unable to locate mysql binary file."
	destroy_conf
	exit 1
fi

if [ ! -x "$sql_dump_cmd" ]; then
	err "unable to locate mysqldump binary file."
	destroy_conf
	exit 1
fi

if ! create_conf; then
	err "unable to write temporary configuration file."
	destroy_conf
	exit 1
fi

check_sql
init_rotate
init_logfile

_dbcount=$(get_sql_db_count)
_dbfinished=0
_dbpassed=0
_gzpassed=0
_dbfailed=0
_gzfailed=0
_percent=0

_start=$(date +%s)
for db in $(get_sql_db); do
	_dbfinished=$(($_dbfinished + 1))
	_percent="$(printf '%i %i' $_dbfinished $_dbcount | awk '{ pc=100*$1/$2; i=int(pc); print (pc-i<0.5)?i:i+1 }')"

	echo -en "\033[s"
	if [ $_percent -ne 100 ]; then
		info2 "-- running backup progress: \033[11C$_percent%"
	fi
	echo -en "\033[u"
	if [ $_percent -eq 100 ]; then
		info "-- running backup progress: \033[11C100%"
	fi

	_backup_dir="$sql_backup/$_host/mysql/$db"
	[ -d $_backup_dir ] || mkdir -p $_backup_dir 2>/dev/null
	file="$db.$rotate_cur.$sql_ext"

	info2log "-- dumping database: $db"
	run_dump "$db" "$_backup_dir/$file"
	if [ $? -ne 0 ]; then
		_dbfailed=$(($_dbfailed + 1))
	else
		_dbpassed=$(($_dbpassed + 1))
	fi

	info2log "-- compressing $file into $file.gz"
	run_gzip "$_backup_dir/$file"
	if [ $? -ne 0 ]; then
		_gzfailed=$(($_gzfailed + 1))
	else
		_gzpassed=$(($_gzpassed + 1))
		_size=$(($(stat -c %s "$_backup_dir/$file.gz") / 1024))
		info2log "-- backup created: filename: $file.gz, size: ${_size}Kb"
	fi
	rm -f "$_backup_dir/$file" >/dev/null 2>&1
done

_end=$(date +%s)
elapsed_time
info "-- backup done, logfile saved to: $sql_log"
info "-------------------------------------------------------------"
info "-- successful database dumps: $_dbpassed"
info "-- failed database dumps: $_dbfailed"
info "-- successful compressed dumps: $_gzpassed"
info "-- failed compressed dumps: $_gzfailed"

info2log "-------------------------------------------------------------"
info2log "-- successful database dumps: $_dbpassed"
info2log "-- failed database dumps: $_dbfailed"
info2log "-- successful compressed dumps: $_gzpassed"
info2log "-- failed compressed dumps: $_gzfailed"

destroy_conf

exit 0
