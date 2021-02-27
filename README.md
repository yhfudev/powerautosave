# Power save scripts


## What it is

This project include the document and scripts to setup servers in home network to sleep when idle. It can be used for NAS/media/backup server which required 24/7 up time.

The basic ideal is to put a sever to suspend state when host idle is detected; and the router, which installed with a wol script, will send out a WOL packet once it detect another host initiates an access request to the suspended server. The server will then power on when received the WOL packet.


In the rest of the document, we'll setup a WOL solution for a server host running Ubuntu, and a OpenWrt router in a home network. The Ubunt server will go to sleep when idle, and waken up by the WOL packet send by OpenWrt router when there's a service request from other hosts.


## Setup WOL on server (Ubuntu)

The network interface card needs the settings of WOL. The best place to set the card would be the config file for udev, for example:
```bash
# /etc/udev/rules.d/70-persistent-net.rules
SUBSYSTEM=="net", ATTR{address}=="11:22:33:44:55:66", NAME="net0", RUN+="/sbin/ethtool -s %k wol g"
```

## Setup suspend+hibernation hybrid mode (Ubuntu)

This step is to set the host to suspend state, and hibernate the host if it's not activated after pre-defined interval, to avoid possible power outage lose.

It will use a swap partition in HDD, the data in RAM will be dumpped to the swap partition, so the size of the partition should larger than the size of RAM memory.

It also need avoiding to use SSD as swap partition, to save on writes to the flash drive.

setup the hibernate time in config file /etc/systemd/sleep.conf,
this is the interval between suspend and hibernation.
```bash
# /etc/systemd/sleep.conf
HibernateDelaySec=180min
```


set swap partition in grub config file /etc/default/grub
```bash
blkid /dev/sdaX

# /etc/default/grub
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash resume=UUID=5c03967e-b9fe-4a2e-8501–05002aa51dd6"

sudo update-initramfs -u -k all
sudo update-grub
```



## Install powerautosave.sh (Ubuntu)

powerautosave.sh is a script to turn server to sleep mode when the server is idle.

```bash
# install packages:
apt update && apt -y install bash prips ipcalc pcp uuid-runtime

# install script
DN_CONF="/etc/powerautosave"
mkdir "${DN_CONF}"
cp powerautosave.service powerautosave.sh libshrt.sh "${DN_CONF}"
cd "${DN_CONF}"
chmod 755 *.sh

# the host ip list, the server will enter to sleep if none is ping-able.
touch "${DN_CONF}/pas-ip.list"
# echo "10.1.1.160/24" >> "${DN_CONF}/pas-ip.list"

# the processes list, the server will enter to sleep if none is running.
touch "${DN_CONF}/pas-proc.list"
# echo "wget scp rsync" >> "${DN_CONF}/pas-proc.list"

# setup the waiting time before sleep in config file
cat >> "${DN_CONF}/powerautosave.conf" <<EOF
# default waiting time before go to sleep
PAS_IDLE_WAIT_TIME=600 # second
PAS_CPU_THRESHOLD=88   # percent
PAS_HD_THRESHOLD=900   # Kbytes
PAS_NET_THRESHOLD=4000 # bytes
EOF

# setup service
cp powerautosave.service /etc/systemd/system/powerautosave.service
systemctl daemon-reload
systemctl enable powerautosave
systemctl restart powerautosave
```

## Install wolonconn.sh (OpenWrt)

wolonconn.sh is a script to send WOL packets to active the server once a connection detected on router.

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
uci set wolonconn.@server[-1].host='datahub.fu'
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

add the line to the /etc/rc.local, before exit

```bash
# /etc/rc.local
/etc/wolonconn.sh &

exit
```
