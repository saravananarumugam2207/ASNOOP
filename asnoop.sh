#!/bin/bash


### default variables
tracing=/sys/kernel/debug/tracing   #available on Linux 2.6 and above
flock=/var/tmp/.ftrace-lock         #temp locking file
bufsize_kb=4096                     #Default Buffer size for caching
opt_duration=0; duration=; opt_name=0; name=; opt_pid=0; pid=; ftext=
opt_start=0; opt_end=0
trap ':' INT QUIT TERM PIPE	# sends execution to end tracing section

function usage {
	cat <<-END >&2
	USAGE: asnoop [-hst] [-d secs] [-p PID] [-n name]
	                 -d seconds      # trace duration, and use buffers
	                 -n name         # process name to match on I/O issue
	                 -p PID          # PID to match on I/O issue
	                 -s              # include start time of I/O (s)
	                 -t              # include completion time of I/O (s)
	                 -h              # this usage message
	  eg,
	        asnoop                  # watch block I/O live (unbuffered)
	        asnoop -d 1             # trace 1 sec (buffered)
	        asnoop -p 181           # trace I/O issued by PID 181 only
END
	exit
}

function warn {
	if ! eval "$@"; then
		echo >&2 "WARNING: command failed \"$@\""
	fi
}

function die {
	echo >&2 "$@"
	[[ -e $flock ]] && rm $flock
	exit 1
}

### process options
while getopts d:hn:p:st opt
do
	case $opt in
	d)	opt_duration=1; duration=$OPTARG ;;
	n)	opt_name=1; name=$OPTARG ;;
	p)	opt_pid=1; pid=$OPTARG ;;
	s)	opt_start=1 ;;
	t)	opt_end=1 ;;
	h|?)	usage ;;
	esac
done
shift $(( $OPTIND - 1 ))

### option logic
(( opt_pid && opt_name )) && die "ERROR: use either -p or -n."
(( opt_pid )) && ftext=" issued by PID $pid"
(( opt_name )) && ftext=" issued by process name \"$name\""
if (( opt_duration )); then
	echo "Tracing block I/O$ftext for $duration seconds (buffered)..."
else
	echo "Tracing block I/O$ftext. Ctrl-C to end."
fi

### ftrace lock
[[ -e $flock ]] && die "ERROR: ftrace may be in use by PID $(cat $flock) $flock"
echo $$ > $flock || die "ERROR: unable to write $flock."

### select awk
(( opt_duration )) && use=mawk || use=gawk	# workaround for mawk fflush()
[[ -x /usr/bin/$use ]] && awk=$use || awk=awk

### setup and begin tracing
cd $tracing || die "ERROR: accessing tracing. Root user? Kernel has FTRACE?"
echo nop > current_tracer
warn "echo $bufsize_kb > buffer_size_kb"
if (( opt_pid )); then
	if ! echo "common_pid==$pid" > events/block/block_rq_issue/filter; then
	    die "ERROR: setting -p $pid. Continuing..."
	fi
fi
if ! echo 1 > events/block/block_rq_issue/enable || \
    ! echo 1 > events/block/block_rq_complete/enable; then
	die "ERROR: enabling block I/O tracepoints. Exiting."
fi
(( opt_start )) && printf "%-14s " "STARTs"
(( opt_end )) && printf "%-14s " "ENDs"
printf "%-16.16s %-6s %-4s %-8s %-12s %-6s %8s\n" \
    "COMM" "PID" "TYPE" "DEV" "BLOCK" "BYTES" "LATms"

#
# Determine output format. It may be one of the following (newest first):
#           TASK-PID   CPU#  ||||    TIMESTAMP  FUNCTION
#           TASK-PID    CPU#    TIMESTAMP  FUNCTION
# To differentiate between them, the number of header fields is counted,
# and an offset set, to skip the extra column when needed.
#
offset=$($awk 'BEGIN { o = 0; }
	$1 == "#" && $2 ~ /TASK/ && NF == 6 { o = 1; }
	$2 ~ /TASK/ { print o; exit }' trace)

### print trace buffer
warn "echo > trace"
( if (( opt_duration )); then
	# wait then dump buffer
	sleep $duration
	cat trace
else
	# print buffer live
	cat trace_pipe
fi ) | $awk -v o=$offset -v opt_name=$opt_name -v name=$name \
    -v opt_duration=$opt_duration -v opt_start=$opt_start -v opt_end=$opt_end '
	# common fields
	$1 != "#" {
		# task name can contain dashes
		comm = pid = $1
		sub(/-[0-9][0-9]*/, "", comm)
		sub(/.*-/, "", pid)
		time = $(3+o); sub(":", "", time)
		dev = $(5+o)
	}

	# block I/O request
	$1 != "#" && $0 ~ /rq_issue/ {
		if (opt_name && match(comm, name) == 0)
			next
		#
		# example: (fields1..4+o) 202,1 W 0 () 12862264 + 8 [tar]
		# The cmd field "()" might contain multiple words (hex),
		# hence stepping from the right (NF-3).
		#
		loc = $(NF-3)
		starts[dev, loc] = time
		comms[dev, loc] = comm
		pids[dev, loc] = pid
		next
	}

	# block I/O completion
	$1 != "#" && $0 ~ /rq_complete/ {
		#
		# example: (fields1..4+o) 202,1 W () 12862256 + 8 [0]
		#
		dir = $(6+o)
		loc = $(NF-3)
		nsec = $(NF-1)

		if (starts[dev, loc] > 0) {
			latency = sprintf("%.2f",
			    1000 * (time - starts[dev, loc]))
			comm = comms[dev, loc]
			pid = pids[dev, loc]

			if (opt_start)
				printf "%-14s ", starts[dev, loc]
			if (opt_end)
				printf "%-14s ", time
			printf "%-16.16s %-6s %-4s %-8s %-12s %-6s %8s\n",
			    comm, pid, dir, dev, loc, nsec * 512, latency
			if (!opt_duration)
				fflush()

			delete starts[dev, loc]
			delete comms[dev, loc]
			delete pids[dev, loc]
		}
		next
	}

	$0 ~ /LOST.*EVENTS/ { print "WARNING: " $0 > "/dev/stderr" }
'

### end tracing
echo 2>/dev/null
echo "Ending tracing..." 2>/dev/null
if ! echo 0 > events/block/block_rq_issue/enable || \
    ! echo 0 > events/block/block_rq_complete/enable; then
	echo >&2 "ERROR: disabling block I/O tracepoints."
	exit 1
fi
(( opt_pid )) && warn "echo 0 > events/block/block_rq_issue/filter"
warn "echo > trace"
warn "rm $flock"
