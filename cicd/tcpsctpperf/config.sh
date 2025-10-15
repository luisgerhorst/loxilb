#!/bin/bash
set -eo pipefail

export OSE_LOXILB_SERVERS=${OSE_LOXILB_SERVERS:-1}

source ../common.sh

echo "#########################################"
echo "Spawning all hosts"
echo "#########################################"

spawn_docker_host --dock-type host --dock-name l3h1
for i in $(seq 1 $OSE_LOXILB_SERVERS)
do
  spawn_docker_host --dock-type host --dock-name l3ep$i
done

spawn_docker_host --dock-type loxilb --dock-name llb1 --cpuset-cpus $(expr $(nproc) - 2)-$(expr $(nproc) - 1)

if [ ! -e $LO_DST/opt-loxilb ]
then
  bpftool_dst=bpftool
  docker cp llb1:/opt/loxilb $LO_DST/opt-loxilb
  rm -rfd $LO_DST/opt-loxilb/cert
  # bpftool=$HOME/lights-out/bpftool-v5.18
  bpftool=bpftool
  for obj in $LO_DST/opt-loxilb/llb_ebpf_main.o
  do
    bpf_obj_name=$(basename $obj .o)
    type_arg=""
    case $bpf_obj_name in
      llb_ebpf_main)
        type_arg="type tc"
        ;;
      llb_ebpf_emain)
        type_arg="type tc"
        ;;
      llb_kern_mon)
        type_arg="type perf_event"
        ;;
      llb_xdp_main)
        type_arg="type xdp.frags/devmap"
        ;;
      llb_kern_sock)
        type_arg="type cgroup/connect4"
        ;;
    esac
    path=/sys/fs/bpf/$bpf_obj_name
    load_arg="prog loadall $obj $path $type_arg"

		sudo sysctl --ignore --write kernel.bpf_precise=$LO_BPF_PRECISE

		set +e
		sudo $bpftool $load_arg \
			2> $LO_DST/$bpftool_dst/$bpf_obj_name.loadall.log
		ec2=$?
		set -e
		sudo dmesg > $LO_DST/${bpftool_dst}/$bpf_obj_name.dmesg.log

		sudo sysctl --ignore --write kernel.bpf_precise=1

		if [ $ec2 -ne 0 ]
		then
			tail $LO_DST/$bpftool_dst/$bpf_obj_name.loadall.log
			exit 1
		fi

		for pinned_prog in $(sudo find "$path" -type f)
		do
			pinned_prog_name=$(basename $pinned_prog)
			sudo bpftool --json --pretty prog dump xlated pinned "$pinned_prog" > $LO_DST/${bpftool_dst}/$bpf_obj_name-$pinned_prog_name.xlated.json
			sudo bpftool prog dump xlated pinned $pinned_prog > $LO_DST/$bpftool_dst/$bpf_obj_name-$pinned_prog_name
		done

		sudo rm -rfd $path
	done
fi

set +x
while ! docker exec -i llb1 bash -c 'cat /var/log/loxilb*.log' | grep 'tc: bpf attach OK for eth0'
do
  sleep 5
done
set -x

echo "#########################################"
echo "Connecting and configuring  hosts"
echo "#########################################"

connect_docker_hosts l3h1 llb1
for i in $(seq 1 $OSE_LOXILB_SERVERS)
do
  connect_docker_hosts l3ep$i llb1
done

sleep 1

# L3 config
config_docker_host --host1 l3h1 --host2 llb1 --ptype phy --addr 10.10.10.1/24 --gw 10.10.10.254
for i in $(seq 1 $OSE_LOXILB_SERVERS)
do
  config_docker_host --host1 l3ep$i --host2 llb1 --ptype phy --addr 31.31.$i.1/24 --gw 31.31.$i.254
done
config_docker_host --host1 llb1 --host2 l3h1 --ptype phy --addr 10.10.10.254/24
for i in $(seq 1 $OSE_LOXILB_SERVERS)
do
  config_docker_host --host1 llb1 --host2 l3ep$i --ptype phy --addr 31.31.$i.254/24
done

sleep 1

# Need to do this as netperf sctp doesn't work without this
$hexec l3h1 ifconfig eth0 0
for i in $(seq 1 $OSE_LOXILB_SERVERS)
do
  $hexec l3ep$i ifconfig eth0 0
done

for ((i=1,port=12865;i<=100;i++,port++))
do
  $dexec llb1 loxicmd create lb 20.20.20.1 --tcp=$port:$port --endpoints=31.31.1.1:1 >> /dev/null
done

# iperf3 --sctp will use tcp:13866 for control data, and sctp:13866 for the
# benchmark data.
$dexec llb1 loxicmd create lb 20.20.20.1 --tcp=13866:13866 --endpoints=31.31.1.1:1 >> /dev/null
for ((i=1,port=13866;i<=100;i++,port++))
do
  $dexec llb1 loxicmd create lb 20.20.20.1 --sctp=$port:$port --endpoints=31.31.1.1:1 >> /dev/null
done

$dexec llb1 loxicmd create lb 20.20.20.1 --tcp=14000:14000 --endpoints=$(seq --sep , --format '31.31.%g.1:1' 1 $OSE_LOXILB_SERVERS) >> /dev/null

set +x
while ! docker exec -i llb1 bash -c 'cat /var/log/loxilb*.log' | grep 'tc: bpf attach OK for ellb1l3h1'
do
  sleep 5
done
while ! docker exec -i llb1 bash -c 'cat /var/log/loxilb*.log' | grep 'tc: bpf attach OK for ellb1l3ep1'
do
  sleep 5
done
set -x
