# Poor man's home PC server power saver

## Table of Contents
<!-- TOC depthFrom:2 -->
- [Poor man's home PC server power saver](#poor-mans-home-pc-server-power-saver)
  - [Table of Contents](#table-of-contents)
  - [What it is](#what-it-is)
  - [Setup WOL on Linux server (Ubuntu)](#setup-wol-on-linux-server-ubuntu)
  - [Setup suspend+hibernation hybrid mode (Ubuntu)](#setup-suspendhibernation-hybrid-mode-ubuntu)
    - [use swap only for suspend](#use-swap-only-for-suspend)
    - [Change the Lid Close Action](#change-the-lid-close-action)
    - [hibernate](#hibernate)
    - [setup a swap file](#setup-a-swap-file)
    - [setup a swap partition](#setup-a-swap-partition)
    - [setup the boot](#setup-the-boot)
    - [update boot](#update-boot)
    - [testing](#testing)
  - [Install powerautosave.sh on Linux server (Ubuntu)](#install-powerautosavesh-on-linux-server-ubuntu)
  - [Install wolonconn.sh on Linux router (OpenWrt)](#install-wolonconnsh-on-linux-router-openwrt)
<!-- /TOC -->

## What it is

This project includes the documents and scripts to set up servers in a home network to sleep when they're idle, and wake up automatically when a request arrives without human involvement. It can be used for a NAS/media/backup server that requires 24/7 uptime. As an example, one of the author's PC servers draws about 100W of power when active and drops to 8W when in an idle state.

The basic idea is to put a server into a suspend state when idle is detected on the host; the router, which is installed with a WOL script, will send out a WOL (Wake-on-LAN) packet once it detects another host initiating an access request to the suspended server. The server will then power on when it receives the WOL packet.

In the rest of the document, we'll set up a WOL solution for a server host running Linux (Ubuntu), and an OpenWrt router in a home network. The Linux server (Ubuntu) will go to sleep when idle and be wakened up by the WOL packet sent by the OpenWrt router when there's a service request from other hosts.

## Setup WOL on Linux server (Ubuntu)

The network interface card requires the settings for Wake-on-LAN (WOL). The best place to configure the card would be the config file for `udev`, for example:
```bash
if ! which ethtool ; then apt install -y ethtool; fi
IFNAME=eno1
MAC=$(ip address show dev $IFNAME | grep ether | awk '{print $2}')
sudo sed -e "s|${IFNAME}:|net0:|" -i /etc/netplan/00-installer-config.yaml
(cat >/dev/stdout<<EOF
SUBSYSTEM=="net", ATTR{address}=="${MAC}", NAME="net0", RUN+="`which ethtool` -s %k wol g"
EOF
) | sudo tee /etc/udev/rules.d/70-persistent-net.rules
```

## Setup suspend+hibernation hybrid mode (Ubuntu)

This step involves setting the host to a suspend state and hibernating the host if it remains inactive for a pre-defined interval, to avoid potential data loss due to power outages.

To enable hibernation, a swap partition on the HDD or a swap file will be utilized. The swap file size recommend to be at least the half the size of RAM.

It is also essential to avoid using an SSD as the swap partition to minimize the number of writes to the flash drive and prolong its lifespan.

### use swap only for suspend

to prevent the kernel from utilizing it for swapping:
```bash
sudo sysctl vm.swappiness
sudo sysctl -w vm.swappiness=1
```

setup config:
```bash
echo "vm.swappiness=1" | tee -a /etc/sysctl.d/local.conf
```

### Change the Lid Close Action

Change the Lid Close Action with the following command:
```bash
# /etc/systemd/logind.conf
# HandleLidSwitch=hibernate
# HandleLidSwitch=suspend-then-hibernate
sudo sed -e 's|[# ]*HandleLidSwitch=.*$|HandleLidSwitch=suspend-then-hibernate|' -i /etc/systemd/logind.conf
```

(option) push power button to power off:
```bash
sudo sed -e 's|[# ]*HandlePowerKey=.*$|HandlePowerKey=poweroff|' -i /etc/systemd/logind.conf
```

Restart the systemd-logind service:
```bash
sudo systemctl restart systemd-logind.service
```

### hibernate
To configure the hibernate time, modify the configuration file located at `/etc/systemd/sleep.conf`. This file allows you to set the interval between the suspend state and hibernation.
```bash
sudo sed -e 's|[# ]*HibernateDelaySec=.*$|HibernateDelaySec=180min|' -i /etc/systemd/sleep.conf

# OR
cat >>/etc/systemd/sleep.conf<<EOF
[Sleep]
HibernateDelaySec=180min
EOF
```

### setup a swap file
Show the swap info
```bash
# show configured swap
swapon --show

free -h
```

To create swap file,
```bash
sudo fallocate -l 1G /swapfile
sudo chmod 600 /swapfile
ls -lh /swapfile
```

make swap and using it:
```bash
sudo mkswap /swapfile
sudo swapon /swapfile

sudo swapon --show
free -h
```

set the file
```bash
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

### setup a swap partition

If you prepared a harddisk partition for swap, you can prepare it by
```bash
PART_SWAP=/dev/sdb3

mkswap ${PART_SWAP}

blkid ${PART_SWAP}
```

to mount the swap in `/etc/fstab`:
```bash
# /dev/sda2       swap       swap       defaults       0 0
echo "$(blkid -o export ${PART_SWAP} | grep '^UUID=') none	swap	sw	0	0" | sudo tee -a /etc/fstab

swapon --all
cat /proc/swaps
```

remove old swap file:
```bash
swapoff /swap.img
# remove config from /etc/fstab
rm -f /swap.img
```


show the info:
```bash
free -mh
```

### setup the boot

update both grub and initramfs,

for swap file, first obtain the UUID of the root partition and the physical offset of the swapfile within it,
```bash
# obtain the UUID of the root partition:
findmnt / -o UUID -n

# obtain the physical offset of the swapfile
filefrag -v /swap|awk 'NR==4{gsub(/\./,"");print $4;}'

# /etc/default/grub
GRUB_CMDLINE_LINUX_DEFAULT="resume=UUID=xxxx resume_offset=yyyyy"
```


for the swap partition, in the GRUB config file /etc/default/grub:
```bash
#blkid /dev/sdaX
CONFIG_UUID=$(cat /proc/swaps | grep -v Size | head -n 1 | awk '{print $1}' | xargs -n 1 blkid -o export | grep '^UUID=')

# /etc/default/grub
# GRUB_CMDLINE_LINUX_DEFAULT="quiet splash resume=${CONFIG_UUID}"
sed -e "s|GRUB_CMDLINE_LINUX_DEFAULT=\"\([^\"]*\)\"|GRUB_CMDLINE_LINUX_DEFAULT=\"quiet splash resume=${CONFIG_UUID}\"|" -i /etc/default/grub
```

include the UUID in the /etc/initramfs-tools/conf.d/resume file:
```bash
echo "RESUME=${CONFIG_UUID}" | sudo tee -a /etc/initramfs-tools/conf.d/resume
```

### update boot

```bash
sudo update-initramfs -u -k all
sudo update-grub
```


### testing
test it:
```bash
sudo systemctl suspend-then-hibernate

sudo systemctl hibernate
```
and signal the server to boot via WOL packet:
```bash
MAC_SVR="11:22:33:44:55:66"
etherwake "${MAC_SVR}"
```

## Install powerautosave.sh on Linux server (Ubuntu)

powerautosave.sh is a script designed to put the server into sleep mode when the server is idle. The script will suspend the host when the specified conditions are met:

- there is nobody logged into the system.
- the CPU is idle, based on the PAS_CPU_THRESHOLD.
- the HDD has low IO, based on the PAS_HD_THRESHOLD.
- the network has low traffic, based on the PAS_NET_THRESHOLD.
- the system has been idle for a long time, defined by the PAS_IDLE_WAIT_TIME.

```bash
# install packages:
apt update && apt -y install bash gawk prips ipcalc uuid-runtime
apt -y install dstat
apt -y install pcp

# install script
DN_CONF="/etc/powerautosave"
sudo mkdir "${DN_CONF}"
sudo cp powerautosave.service powerautosave.sh libshrt.sh "${DN_CONF}"
cd "${DN_CONF}"
sudo chmod 755 *.sh

# the host ip list, the server will enter to sleep if none is ping-able.
touch "${DN_CONF}/pas-ip.list"
# echo "10.1.1.160/24" >> "${DN_CONF}/pas-ip.list"

# the processes list, the server will enter to sleep if none is running.
touch "${DN_CONF}/pas-proc.list"
echo "wget curl scp rsync dstat" | sudo tee "${DN_CONF}/pas-proc.list"

# setup the waiting time before sleep in config file
(cat >/dev/stdout <<EOF
# default waiting time before go to sleep
PAS_IDLE_WAIT_TIME=900 # second
PAS_CPU_THRESHOLD=88   # percent
PAS_HD_THRESHOLD=900   # Kbytes
PAS_NET_THRESHOLD=4000 # bytes
EOF
) | sudo tee "${DN_CONF}/powerautosave.conf"

# setup service
sudo cp powerautosave.service /etc/systemd/system/powerautosave.service
sudo systemctl daemon-reload
sudo systemctl enable powerautosave
sudo systemctl restart powerautosave
sudo systemctl status powerautosave

journalctl -u powerautosave -b
```

To reload config:
```bash
kill -s SIGUSR1 $(ps -ef | grep owerautosave | grep -v grep | awk '{print $2}')
```


## Install wolonconn.sh on Linux router (OpenWrt)

The script "wolonconn.sh" serves the purpose of sending Wake-on-LAN (WOL) packets to activate the server once a connection is detected on the OpenWrt router.

To ensure proper functionality, it is important to verify that the request packet from the client to the server host passes through the OpenWrt router. The server can either be located behind the router if the packet originates from the outside (Internet), or in a separate virtual LAN if the packet is from a client also behind the router.

Additionally, the server host should be listed in the "DHCP and DNS -- Static Leases" table, which includes its host name, IP address, and MAC address. This listing allows the program to query the MAC address and interface required for the server host, ensuring that the WOL packets are sent to the correct destination and the server is properly activated upon connection detection.


```bash
# install packages:
opkg update; opkg install bash curl conntrack owipcalc etherwake uuidgen

# install script
cp wolonconn.sh /etc/wolonconn.sh
chmod 755 /etc/wolonconn.sh

# setup config
rm -f /etc/config/wolonconn
touch /etc/config/wolonconn
uci set wolonconn.basic='config'
uci set wolonconn.basic.filetemp='/tmp/wol-on-conn.temp'
uci set wolonconn.basic.filelog='/tmp/wol-on-conn.log'

uci add wolonconn server
uci set wolonconn.@server[-1].host='myhostname'
uci set wolonconn.@server[-1].ports='22 80 443'
#uci set wolonconn.@server[-1].interface='br-lan'
#uci set wolonconn.@server[-1].mac='11:22:33:44:55:01'

uci add wolonconn server
uci set wolonconn.@server[-1].host='10.1.1.23'
uci set wolonconn.@server[-1].ports='22 80'

uci add wolonconn client
uci set wolonconn.@client[-1].iprange='10.1.0.0/16'

# uci revert wolonconn
uci commit wolonconn

uci show wolonconn
```

add the line to the file `/etc/rc.local`, before 'exit'

```bash
# /etc/rc.local
/etc/wolonconn.sh &

exit
```


To reload config:
```bash
kill -s SIGUSR1 $(ps | grep wolonconn | grep -v grep | awk '{print $1}')
```



