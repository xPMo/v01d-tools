#!/usr/bin/env zsh

setopt extendedglob multios

debug(){
	((verbosity < $1)) && return 0
	local pfx
	case $1 in
		-1) pfx='%B%F{red}[E]%b%f' ;;
		0) pfx='%B%F{yellow}[W]%b%f' ;;
		1) pfx='%B[I]%b' ;;
		2|3) pfx='%F{cyan}[D]%f' ;;
	esac
	shift
	print -u2 -l -P "$pfx ${^@}"
}

help(){
	print -u2 \
"Usage: $ZSH_ARGZERO [options] [-|-- nmap_options host ...]

Options:
	--help         -h        Show this help
	--view         -V        View report in browser
	--dir DIR      -d DIR    Directory to save scan to (default: PWD)
	--ports PORTS  -p PORTS  Specify the ports to scan (default: 80,8080,443,8443)
	--timeout SEC  -t SEC    Set timeout for CutyCapt  (default: 10)
	--force        -f        Consider all open ports as http(s)
	--sudo         -S        Run nmap with sudo (for OS detection)
	--verbose      -v        Increase verbosity
	--quiet        -q        Decrease verbosity
"
	exit $1
}

peek(){
	local -i t=${timeout:#-*}
	# minimum of 1 second
	((t = t < 1 ? 10 : t))
	images+=("$service://$remote" "$dir/images/$remote.png")
	# BlackArch installs as /usr/bin/CutyCapt
	timeout $t ${commands[cutycapt]:-$commands[CutyCapt]} \
		--url="$service://$1" --insecure --out="$2" >/dev/null 2>&1 &
	pids+=($!)
}

zmodload zsh/zutil
zmodload zsh/files
zparseopts -D -E -F - \
	h=help -help=help \
	d:=dir -dir:=dir \
	p+:=ports -ports+:=ports \
	t:=timeout -timeout:=timeout \
	V=view -view=view \
	f=force -force=force \
	S=sudo -sudo=sudo \
	v+=flagv -verbosity+=flagv \
	q+=flagq -quiet+=flagq \
	|| help 1

# remove first -- or -
end_opts=$@[(i)(--|-)]
set -- "${@[0,end_opts-1]}" "${@[end_opts+1,-1]}"

# help
(($#help)) && help 0
if (($#)); then
	debug -1 "No host(s) provided."
	help 1
fi

# Check installed programs
for prog (
	'(CutyCapt|cutycapt)'
	nmap
	xdg-open
	xmlstarlet
) if ! (($+commands[(i)$~prog])); then
		debug -1 "Unable to find %F{yellow}$prog%f. Is it installed?"
		exit 1
fi

integer verbosity="1+${#flagv}-${#flagq}"

# Filenames
dir=${dir[-1]:-'.'}
scan=${(%)scan[-1]:-$dir/scan_%D{%F_%T}}
report=$dir/report.html

# Directory
if ! mkdir -p "$dir/images" "${scan:h}"; then
	debug -1 "Could not create directories."
	exit 1
fi

# Create files beforehand in case we are running nmap with sudo
debug 3 "Creating scan logs at %F{yellow}${scan//(#m)[\\%]/$MATCH$MATCH}.{gnmap,nmap,xml}.%f"
if ! : > "$scan".{gnmap,nmap,xml}; then
	debug -1 "Could not create files in %F{yellow}$dir%f."
	exit 1
fi

# Ports: avoid duplicates
ports=(${(@s[,])${ports:#-?*}})
ports=(${(uon)ports})

# Call nmap
debug 2 "Calling %Bnmap%b on %F{magenta}$*%f with port(s) %F{green}${(j[,])ports:-80,443,8080,8443}%f"
debug 1 "${(@f)"$(
	${sudo:+sudo} nmap -A -Pn -n --open -oA "$scan" \
	-p${(j[,])ports:-80,443,8080,8443} "$@"
)"//(#m)[\\%]/$MATCH$MATCH}" # escape backslash and percent for print -P


IFS=$'\t\n'
while read -r remote; do
	service=${remote%%:*}
	remote=${remote#$service:}
	case $service in
		http|https)
			debug 2 "Found service %F{blue}$service%f for %F{magenta}$remote%f"
			peek "$remote" "$dir/images/$remote.png"
			;;
		'') # empty
			if (($#force)); then
				debug 2 "Unknown service for %F{magenta}$remote%f; trying %F{blue}http(s)%f"
				service=http  peek "$remote" "$dir/images/$remote.png"
				service=https peek "$remote" "$dir/images/$remote-s.png"
			else
				debug 3 "Unknown service for %F{magenta}$remote%f; skipping"
			fi
			;;
		*) # probably not http
			if (($#force)); then
				debug 2 "Unknown service %F{blue}$service%f for %F{magenta}$remote%f; trying %F{blue}http(s)%f"
				service=http  peek "$remote" "$dir/images/$remote.png"
				service=https peek "$remote" "$dir/images/$remote-s.png"
			else
				debug 3 "Unknown service %F{blue}$service%f for %F{magenta}$remote%f; skipping"
			fi
			;;
	esac
done < <(
	# Get open ports from scan: [service name]:[addr]:[port]
	xmlstarlet sel -T -t -m "//port/state[@state='open']/.." \
		-v service/@name -o ':' -v ../../address/@addr -o ':' -v @portid --nl \
		< "$scan.xml"
)

# Get exit codes from cutycapt
for pid ($pids){
	wait $pid
	((total++, failed += ($? != 0)))
}

# Write report
debug 2 'Writing report...'
{
	print '<html><body><br/>'
	for remote img ("${(@)images}"){
		print "<a href=${(qqq)remote}><span><h3>${remote//[<>]}</h3><hl/><img src=${(qqq)img} width=600/></span></a>"
	}
	print '</body></html>'
} > $report

if (($#view)); then
	debug 2 'Opening report...'
	xdg-open $report
fi

if ((failed)); then
	debug 0 "$failed / $total failed."
fi
return 0
