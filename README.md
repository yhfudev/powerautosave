# Power save scripts

Some scripts for saving PC power.



## Install powerautosave

```bash
mkdir /etc/powerautosave/
cp powerautosave.service powerautosave.sh libshrt.sh /etc/powerautosave/
cd /etc/powerautosave/
chmod 755 *.sh

touch /etc/powerautosave/pas-ip.list
touch /etc/powerautosave/pas-proc.list
# echo "10.1.1.160/24" >> /etc/powerautosave/pas-ip.list
# echo "wget" >> /etc/powerautosave/pas-proc.list

# config file
echo "PAS_IDLE_WAIT_TIME=600" >> /etc/powerautosave/powerautosave.conf

cp powerautosave.service /etc/systemd/system/powerautosave.service
systemctl enable powerautosave
systemctl restart powerautosave
```


