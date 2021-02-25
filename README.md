# Power save scripts

Some scripts for saving PC power.


## Install powerautosave.sh (Ubuntu)

powerautosave.sh is a script to turn server to sleep mode when the server is idle.

```bash
# install packages:
apt update && apt -y install bash prips ipcalc pcp uuid-runtime

# install script
mkdir /etc/powerautosave/
cp powerautosave.service powerautosave.sh libshrt.sh /etc/powerautosave/
cd /etc/powerautosave/
chmod 755 *.sh

# the host ip list, the server will enter to sleep if none is ping-able.
touch /etc/powerautosave/pas-ip.list
# echo "10.1.1.160/24" >> /etc/powerautosave/pas-ip.list

# the processes list, the server will enter to sleep if none is running.
touch /etc/powerautosave/pas-proc.list
# echo "wget" >> /etc/powerautosave/pas-proc.list

# setup the waiting time before sleep in config file
echo "PAS_IDLE_WAIT_TIME=600" >> /etc/powerautosave/powerautosave.conf

# setup service
cp powerautosave.service /etc/systemd/system/powerautosave.service
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
uci set wolonconn.@server[-1].ip='10.1.1.178'
uci set wolonconn.@server[-1].ports='22 80 443'
#uci set wolonconn.@server[-1].interface='br-lan'
#uci set wolonconn.@server[-1].mac='11:22:33:44:55:01'

uci add wolonconn server
uci set wolonconn.@server[-1].ip='10.1.1.23'
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
