FROM ubuntu:latest
ENV DEBIAN_FRONTEND noninteractive

# Install essential packages to get this going
RUN apt-get update \
       && apt-get dist-upgrade \
       && apt-get install -y wget nano \
          apt-utils equivs deborphan \
          rtl-sdr librtlsdr0 librtlsdr-dev \
          x11-apps wget novnc tightvncserver fluxbox

# Create and install meta package for qt5-default dependency
RUN mkdir -p /usr/local/src/qt5-deps
WORKDIR /usr/local/src/qt5-deps
RUN <<'EOF' cat >> /usr/local/src/qt5-deps/qt5-default
Section: misc
Priority: optional
Standards-Version: 3.9.2

Package: qt5-default
Version: 5.15.2
Description: qt5-default meta package
EOF
RUN equivs-build qt5-default && dpkg -i ./qt5-default_5.15.2_all.deb

# Download and install SDRReceiver
WORKDIR /usr/local/src
RUN wget https://github.com/jeroenbeijer/SDRReceiver/releases/download/latest/SDRReceiver_1.0-1_linux_x86_64.tar.gz \
   && tar xzvf SDRReceiver_1.0-1_linux_x86_64.tar.gz
WORKDIR /usr/local/src/SDRReceiver
RUN apt-get install --reinstall -y ./*.deb
RUN ldconfig

# Download and install JAERO app
WORKDIR /usr/local/src
RUN wget https://github.com/andermatt64/JAERO/releases/download/latest/jaero_1.1-de-21-g66d8f73-1_linux_x86_64.tar.gz \
   && tar xzvf jaero_1.1-de-21-g66d8f73-1_linux_x86_64.tar.gz
WORKDIR /usr/local/src/jaero
RUN apt-get install --reinstall -y ./*.deb
RUN ldconfig

RUN mkdir -p /root/.local/share/JAERO/planes /var/log/jaero
RUN touch /var/log/jaero/`date "+acars-log-%y-%m-%d.txt"`

# Create main JAERO conf template
RUN <<'EOF' cat >> /root/jaero.conf
[General]
lineEditdonotdisplaysus=26 0A C0 00 14 16
PLANE_LOG_DB_SCHEMA_VERSION=2
checkBoxdropnontextmsgs=true
checkBoxbeepontextmessage=false
checkBoxlogenable=SEDJAERO_ACARS_LOGGING
lineEditlogdir=/var/log/jaero
lineEditDBURL2=https://junzis.com/adb/download
lineEditplanelookup=http://www.flightradar24.com/data/airplanes/{REG}
lineEditplanesfolder=/root/.local/share/JAERO/planes
checkOutputDecodedMessageToUDPPort=true
checkSetStationId=true
lineEditstationid=SEDJAERO_FEEDER_ID
comboBoxbps=0
comboBoxlbw=0
zmqAudioInputEnabled=true
zmqAudioInputReceiveAddress=tcp://127.0.0.1:6003
zmqAudioInputReceiveTopic=VFOXX
localAudioOutEnabled=false
geometry=@ByteArray(\x1\xd9\xd0\xcb\0\x3\0\0\0\0\0\0\0\0\0\0\0\0\x3\xff\0\0\x2\xe9\0\0\0\0\0\0\0\x16\0\0\x3\xff\0\0\x2\xe6\0\0\0\0\x2\0\0\0\x4\0\0\0\0\0\0\0\0\x16\0\0\x3\xff\0\0\x2\xe6)
[feeders]
1\format=4
1\host=SEDJAERO_INJEST_HOST
1\port=SEDJAERO_INJEST_PORT
size=1
EOF

# Create SDRReceiver conf template
RUN <<'EOF' cat >> /root/sdr.conf
sample_rate=SEDJAERO_SDR_SAMPLERATE
center_frequency=1545600000
zmq_address=tcp://*:6003
auto_start=1
auto_start_tuner_idx=0
tuner_gain=SEDJAERO_SDR_GAIN
correct_dc_bias=0
mix_offset=0
[main_vfos]
size=1
1\frequency=1545115000
1\out_rate=384000
[vfos]
size=12
1\frequency=1545004150
1\gain=5
1\filter_bandwidth=1200
1\data_rate=600
1\topic=VFO01
2\frequency=1545114100
2\gain=5
2\filter_bandwidth=1200
2\data_rate=600
2\topic=VFO02
3\frequency=1545119150
3\gain=5
3\filter_bandwidth=1200
3\data_rate=600
3\topic=VFO03
4\frequency=1545123450
4\gain=5
4\filter_bandwidth=2200
4\data_rate=1200
4\topic=VFO04
5\frequency=1545129050
5\gain=5
5\filter_bandwidth=1200
5\data_rate=600
5\topic=VFO05
6\frequency=1545159150
6\gain=5
6\filter_bandwidth=1200
6\data_rate=600
6\topic=VFO06
7\frequency=1545164150
7\gain=5
7\filter_bandwidth=1200
7\data_rate=600
7\topic=VFO07
8\frequency=1545184150
8\gain=5
8\filter_bandwidth=1200
8\data_rate=600
8\topic=VFO08
9\frequency=1545189150
9\gain=5
9\filter_bandwidth=1200
9\data_rate=600
9\topic=VFO09
10\frequency=1545214150
10\gain=5
10\filter_bandwidth=1200
10\data_rate=600
10\topic=VFO10
11\frequency=1545219150
11\gain=5
11\filter_bandwidth=1200
11\data_rate=600
11\topic=VFO11
12\frequency=1545224150
12\gain=5
12\filter_bandwidth=1200
12\data_rate=600
12\topic=VFO12
EOF

# Fix novnc default index page
RUN ln -s /usr/share/novnc/vnc_lite.html /usr/share/novnc/index.html

# Create our Startup Script
RUN <<'EOF' cat >> /root/docker-entrypoint.sh
#!/bin/bash
# Ensure our variables are set
for envvarname in JAERO_FEEDER_ID JAERO_DEVICE_SERIAL JAERO_SDR_GAIN JAERO_SDR_SAMPLERATE JAERO_INJEST_HOST JAERO_INJEST_PORT VNC_RESOLUTION VNC_PASSWORD NOVNC_PORT; do
   if [[ -z "${!envvarname}" ]]; then
      echo "Variable $envvarname not set in docker-compose.yml!"
      exit 1
   else
      sed -i "s/SED$envvarname/${!envvarname}/" /root/sdr.conf /root/jaero.conf
   fi
done

# Generate VNC Server password
mkdir -p /root/.vnc && chmod 700 /root/.vnc
echo ${VNC_PASSWORD} | vncpasswd -f > /root/.vnc/passwd
chmod 600 /root/.vnc/passwd

# Find rtl device ID based on the serial
mapfile -t RTL_TEST_OUTPUT < <(timeout 1s rtl_test -d 0 2>&1 | grep -P '^\s+\d+:\s.*?,.*?,\s+SN:\s+.*?$' | IFS=$'\n' sed -n 's/^\s*\([^:]*\):[^,]*,[^,]*,\s*SN:\s*\(.*\)$/\1,\2/; s/\s*$//p' || true)
for RTL_TEST_OUTPUT_LINE in "${RTL_TEST_OUTPUT[@]}"; do
   if [[ "${RTL_TEST_OUTPUT_LINE##*,}" == "${JAERO_DEVICE_SERIAL}" ]]; then
      OUTPUT_DEVICE_ID="${RTL_TEST_OUTPUT_LINE%%,*}"
   fi
done

# Update sdr.conf to match the correct device ID
sed -i "s/auto_start_tuner_idx=.*/auto_start_tuner_idx=$OUTPUT_DEVICE_ID/" /root/sdr.conf
rm -Rf /tmp/.X*
export XDG_RUNTIME_DIR=/root/.cache/xdgr
export XKB_DEFAULT_RULES=base
export DISPLAY=":1"

# Launch VNC Server, and NoVNC Web interface
USER=root /usr/bin/vncserver -depth 16 -geometry ${VNC_RESOLUTION} :1
/usr/share/novnc/utils/launch.sh --listen ${NOVNC_PORT} --vnc localhost:5901 --web /usr/share/novnc/ > /dev/null 2>&1 &

# Get latest planes DB
wget -q https://junzis.com/adb/download/aircraft_db.zip -O /root/.local/share/JAERO/planes/new.aircrafts_dump.zip

# this is the default jaero app conf directory and i'm not messing with the source code.. so we use it as is
mkdir -p /root/.config/Jontisoft && cd /root/.config/Jontisoft

# Create 12 JAERO Conf files, one per VFO, using the template, then Launch them one by one.. and set the data rate
grep "data_rate" /root/sdr.conf | while read line; do
   i=$(echo "$line" | sed -e 's/data.*//')
   if [ `echo -n $i | wc -m` == 1 ]; then
     i="0$i"
   fi
   bw=$(echo "$line" | sed -e 's/.*=//');
   cp /root/jaero.conf "JAERO [VFO$i].conf";
   sed -i "s/VFOXX/VFO$i/" "JAERO [VFO$i].conf";
   if [ "$bw" == 1200 ]; then
     sed -i "s/comboBoxbps.*/comboBoxbps=1/" "JAERO [VFO$i].conf";
     sed -i "s/comboBoxlbw.*/comboBoxlbw=1/" "JAERO [VFO$i].conf";
   fi
   if [ "$JAERO_LOGGING" == "true" ]; then
      jaero -s VFO$i 2>&1 | awk -W interactive '{print "[JAERO] " strftime("%Y/%m/%d %H:%M:%S", systime()) " " $0}' &
   else
      jaero -s VFO$i > /dev/null 2>&1 &
   fi
done;

# Play ACARS logs on stdout
if [ "$JAERO_ACARS_LOGGING" == "true" ]; then
   CURRENTLOGFILE=`date "+acars-log-%y-%m-%d.txt"`
   tail -F $CURRENTLOGFILE 2>/dev/null | awk -W interactive '{print "[ACARS] " strftime("%Y/%m/%d %H:%M:%S", systime()) " " $0}' &
   TAILPID=$!
   while true; do
      NEWLOGFILE=`ls -t \`date "+acars-log-%y-%m-%d.txt"\` 2>/dev/null |head -n1 2>/dev/null`
      if [[ "$NEWLOGFILE" != "$CURRENTLOGFILE" ]]; then
         kill $TAILPID 2>/dev/null
         CURRENTLOGFILE=$NEWLOGFILE
         tail -F $CURRENTLOGFILE 2>/dev/null | awk -W interactive '{print "[ACARS] " strftime("%Y/%m/%d %H:%M:%S", systime()) " " $0}' &
         TAILPID=$!
      fi
      sleep 60
   done &
fi

# Launch SDRReceiver
if [ "$SDRRECEIVER_LOGGING" == "true" ]; then
   SDRReceiver -s /root/sdr.conf 2>&1 | awk -W interactive '{print "[SDRReceiver] " strftime("%Y/%m/%d %H:%M:%S", systime()) " " $0}'
else
   SDRReceiver -s /root/sdr.conf > /dev/null 2>&1
fi
EOF

RUN chmod +x /root/docker-entrypoint.sh
WORKDIR /root

RUN apt-get clean -y && apt-get autoclean -y && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

CMD ["/root/docker-entrypoint.sh"]
