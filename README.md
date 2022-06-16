# Poor man's home PC server power saver

## What it is

This project include the documents and scripts to setup servers in home network to sleep when it's idle, and wake up when request arrives automatically without human involved. It can be used for NAS/media/backup server which required 24/7 up time. As a example, one of the author's PC server draw about 100W power on active, and it drop to 8W when in idle state.

The basic ideal is to put a sever to suspend state when host idle is detected; and the router, which is installed with a WOL script, will send out a WOL packet once it detect another host initiates an access request to the suspended server. The server will then power on when received the WOL packet.


In the rest of the document, we'll setup a WOL solution for a server host running Linux (Ubuntu), and a OpenWrt router in a home network. The Linux server (Ubuntu) will go to sleep when idle, and waken up by the WOL packet send by OpenWrt router when there's a service request from other hosts.


## Setup WOL on Linux server (Ubuntu)

The network interface card needs the settings of WOL. The best place to set the card would be the config file for udev, for example:
```bash
if ! which ethtool ; then apt install -y ethtool; fi
IFNAME=eno1
MAC=$(ifconfig $IFNAME | grep ether | awk '{print $2}')
sed -e "s|${IFNAME}:|net0:|" -i /etc/netplan/00-installer-config.yaml
cat >>/etc/udev/rules.d/70-persistent-net.rules<<EOF
SUBSYSTEM=="net", ATTR{address}=="${MAC}", NAME="net0", RUN+="`which ethtool` -s %k wol g"
EOF
```

## Setup suspend+hibernation hybrid mode (Ubuntu)

This step is to set the host to suspend state, and hibernate the host if it's not activated after pre-defined interval, to avoid possible power outage lose.

It will use a swap partition in HDD, the data in RAM will be dumpped to the swap partition, so the size of the partition should larger than the size of RAM memory.

It also need avoiding to use SSD as swap partition, to save on writes to the flash drive.

setup the hibernate time in config file /etc/systemd/sleep.conf,
this is the interval between suspend and hibernation.
```bash
sed -e 's|#HibernateDelaySec=.*$|HibernateDelaySec=180min|' -i /etc/systemd/sleep.conf

# OR
cat >>/etc/systemd/sleep.conf<<EOF
[Sleep]
HibernateDelaySec=180min
EOF
```

test it:
```
sudo systemctl suspend-then-hibernate
```

change Lid Close Action:
```
# /etc/systemd/logind.conf
HandleLidSwitch=suspend-then-hibernate
```
restart systemd-logind service
```
sudo systemctl restart systemd-logind.service
```





set swap partition in grub config file /etc/default/grub
```bash
blkid /dev/sdaX

# /etc/default/grub
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash resume=UUID=5c03967e-b9fe-4a2e-8501–05002aa51dd6"

sudo update-initramfs -u -k all
sudo update-grub
```



## Install powerautosave.sh on Linux server (Ubuntu)

powerautosave.sh is a script to turn server to sleep mode when the server is idle.
It will turn the host to suspend mode when there're
* nobody login to the system
* CPU is idle, PAS_CPU_THRESHOLD
* HDD has low IO, PAS_HD_THRESHOLD
* network has low traffic, PAS_NET_THRESHOLD
* system is idle for a long time, PAS_IDLE_WAIT_TIME


```bash
# install packages:
apt update && apt -y install bash prips ipcalc uuid-runtime
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
echo "wget scp rsync" | sudo tee "${DN_CONF}/pas-proc.list"

# setup the waiting time before sleep in config file
cat >> "${DN_CONF}/powerautosave.conf" <<EOF
# default waiting time before go to sleep
PAS_IDLE_WAIT_TIME=900 # second
PAS_CPU_THRESHOLD=88   # percent
PAS_HD_THRESHOLD=900   # Kbytes
PAS_NET_THRESHOLD=4000 # bytes
EOF

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

wolonconn.sh is a script to send WOL packets to active the server once a connection detected on router.

Be sure that the request packet from the client to the server host will pass through the OpenWrt router. The server can be either behind the router if the packet from outsides(Internet), or in a separate virtual LAN if the packet is from the client also behind the router.

And the server host should also be listed in the "DHCP and DNS -- Static Leases" table, includes its host name, IP and MAC address.
So that the program can query the MAC address and interface for the server host.


```bash
# install packages:
opkg update
opkg install bash curl conntrack owipcalc etherwake uuidgen

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
```

add the line to the /etc/rc.local, before 'exit'

```bash
# /etc/rc.local
/etc/wolonconn.sh &

exit
```


To reload config:
```bash
kill -s SIGUSR1 $(ps | grep wolonconn | grep -v grep | awk '{print $1}')
```



