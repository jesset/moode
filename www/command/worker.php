#!/usr/bin/php
<?php
/**
 * moOde audio player (C) 2014 Tim Curtis
 * http://moodeaudio.org
 *
 * tsunamp player ui (C) 2013 Andrea Coiutti & Simone De Gregori
 * http://www.tsunamp.com
 *
 * This Program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 3, or (at your option)
 * any later version.
 *
 * This Program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * 2018-01-26 TC moOde 4.0
 *
 */

require_once dirname(__FILE__) . '/../inc/playerlib.php';

//
sysCmd('truncate /var/log/moode.log --size 0');
workerLog('worker: - Start');
//

// daemonize ourselves
$lock = fopen('/run/worker.pid', 'c+');
if (!flock($lock, LOCK_EX | LOCK_NB)) {
	workerLog('worker: Already running');
	exit('already running');
}

switch ($pid = pcntl_fork()) {
	case -1:
		$logmsg = 'worker: Unable to fork';
		workerLog($logmsg);
		exit($logmsg . "\n");
	case 0: // child process
		break;
	default: // parent process
		fseek($lock, 0);
		ftruncate($lock, 0);
		fwrite($lock, $pid);
		fflush($lock);
		exit;
}
 
if (posix_setsid() === -1) {
	$logmsg = 'worker: Could not setsid';
	workerLog($logmsg);
	exit($logmsg . "\n");
}
 
fclose(STDIN);
fclose(STDOUT);
fclose(STDERR);

$stdIn = fopen('/dev/null', 'r'); // set fd/0
$stdOut = fopen('/dev/null', 'w'); // set fd/1
$stdErr = fopen('php://stdout', 'w'); // a hack to duplicate fd/1 to 2

pcntl_signal(SIGTSTP, SIG_IGN);
pcntl_signal(SIGTTOU, SIG_IGN);
pcntl_signal(SIGTTIN, SIG_IGN);
pcntl_signal(SIGHUP, SIG_IGN);
workerLog('worker: Successfully daemonized');

//
workerLog('worker: - Init');
//

// sqlite db 
sysCmd('chmod -R 0777 /var/local/www/db');
// cache cfg_system in session vars
playerSession('open', '', ''); // load session vars
// cache cfg_radio in session vars
$dbh = cfgdb_connect();
$result = cfgdb_read('cfg_radio', $dbh);
foreach ($result as $row) {
	$_SESSION[$row['station']] = array('name' => $row['name'], 'permalink' => $row['permalink'], 'logo' => $row['logo']);
}
/* enable this only if theme settings will be used by php
// cache cfg_theme in session vars
$result = cfgdb_read('cfg_theme', $dbh);
foreach ($result as $row) {
	$_SESSION[$row['theme_name']] = array('tx_color' => $row['tx_color'], 'bg_color' => $row['bg_color'], 'mbg_color' => $row['mbg_color']);
}*/
workerLog('worker: Session loaded');
workerLog('worker: Debug logging (' . ($_SESSION['debuglog'] == '1' ? 'on' : 'off') . ')');

// store platform data
playerSession('write', 'hdwrrev', getHdwrRev());
playerSession('write', 'kernelver', strtok(shell_exec('uname -r'),"\n"));
playerSession('write', 'procarch', strtok(shell_exec('uname -m'),"\n"));
$mpdver = explode(" ", strtok(shell_exec('mpd -V | grep "Music Player Daemon"'),"\n"));
playerSession('write', 'mpdver', $mpdver[3]);
$lastinstall = checkForUpd('/var/local/www/');
$_SESSION['pkgdate'] = $lastinstall['pkgdate'];

/*// exit if running an unsupported hdwrrev
if (substr($_SESSION['hdwrrev'], 0, 5) == '?????') {
	workerLog('worker: Unsupported hardware platform (' . $_SESSION['hdwrrev'] . ')');
	workerLog('worker: exited');
	exit;
}*/

// exit if running an unsupported kernel config
if (($_SESSION['feat_bitmask'] & FEAT_ADVKERNELS) ||
	($_SESSION['procarch'] == 'armv6l' && false !== strpos($_SESSION['kernelver'], '-')) ||
	($_SESSION['procarch'] == 'armv7l' && false === strpos($_SESSION['kernelver'], '-v7+'))) {
	if ($_SESSION['feat_bitmask'] & FEAT_ADVKERNELS) {
		workerLog('worker: Unsupported configuration (' . $_SESSION['feat_bitmask'] . ')');
	}
	else {
		workerLog('worker: Unsupported Linux kernel (' . $_SESSION['kernelver'] . ')');
	}	
	workerLog('worker: exited');
	exit;
}

// log platform data 
workerLog('worker: Host (' . $_SESSION['hostname'] . ')');
workerLog('worker: Hdwr (' . $_SESSION['hdwrrev'] . ')');
workerLog('worker: Arch (' . $_SESSION['procarch'] . ')');
workerLog('worker: Kver (' . $_SESSION['kernelver'] . ')');
workerLog('worker: Ktyp (' . $_SESSION['kernel'] . ')');
workerLog('worker: Gov  (' . $_SESSION['cpugov'] . ')');
workerLog('worker: Rel  (Moode ' . getMoodeRel('verbose') . ')'); // X.Y yyyy-mm-dd ex: 2.6 2016-06-07
workerLog('worker: Upd  (' . $_SESSION['pkgdate'] . ')');
workerLog('worker: MPD  (' . $_SESSION['mpdver'] . ')');

// auto-configure if indicated
if (file_exists('/boot/moodecfg.txt')) {
	workerLog('worker: Auto-configure initiated');
	autoConfig('/boot/moodecfg.txt');
	sysCmd('reboot');
	//workerLog('worker: Auto-configure done, reboot to make changes effective');
}

// boot device config
$result = sysCmd('vcgencmd otp_dump | grep 17:');
if ($result[0] == '17:3020000a') {
	$msg = 'USB boot enabled';
	sysCmd('sed -i /program_usb_boot_mode/d ' . $_SESSION['res_boot_config_txt']);
}
else {
	$msg = 'USB boot not enabled yet';
}
workerLog('worker: ' . $msg);

// file system expansion status
$result = sysCmd("df | grep root | awk '{print $2}'");
$msg = $result[0] > 3000000 ? 'File system expanded' : 'File system not expanded yet'; 
workerLog('worker: ' . $msg);
// turn on/off hdmi port
$cmd = $_SESSION['hdmiport'] == '1' ? 'tvservice -p' : 'tvservice -o';
sysCmd($cmd . ' > /dev/null');
workerLog('worker: HDMI port ' . ($_SESSION['hdmiport'] == '1' ? 'on' : 'off'));

// ensure certain files exist
if (!file_exists('/var/local/www/currentsong.txt')) {sysCmd('touch /var/local/www/currentsong.txt');}
if (!file_exists('/var/local/www/libcache.json')) {sysCmd('touch /var/local/www/libcache.json');}
if (!file_exists('/var/local/www/playhistory.log')) {sysCmd('touch /var/local/www/playhistory.log');}
if (!file_exists('/var/local/www/sysinfo.txt')) {sysCmd('touch /var/local/www/sysinfo.txt');}
if (!file_exists('/var/log/moode.log')) {sysCmd('touch /var/log/moode.log');}
// sps metadata
if (!file_exists('/var/local/www/imagesw/spscover.jpg')) {sysCmd('touch /var/local/www/imagesw/spscover.jpg');}
if (!file_exists('/var/local/www/imagesw/spscover.png')) {sysCmd('touch /var/local/www/imagesw/spscover.png');}
if (!file_exists('/var/local/www/spscache.json')) {sysCmd('touch /var/local/www/spscache.json');}

// permissions
sysCmd('chmod 0777 /var/lib/mpd/music/RADIO/*.*');
sysCmd('chmod 0777 /var/local/www/currentsong.txt');
sysCmd('chmod 0777 /var/local/www/libcache.json');
sysCmd('chmod 0777 /var/local/www/playhistory.log');
sysCmd('chmod 0777 /var/local/www/sysinfo.txt');
sysCmd('chmod 0666 /var/log/moode.log');
// sps metadata
sysCmd('chmod 0777 /var/local/www/imagesw/spscover.jpg');
sysCmd('chmod 0777 /var/local/www/imagesw/spscover.png');
sysCmd('chmod 0777 /var/local/www/spscache.json');
workerLog('worker: File check ok');

//
workerLog('worker: - Network');
//

// CHECK ETH0
$eth0 = sysCmd('ip addr list | grep eth0');
if (!empty($eth0)) {
	workerLog('worker: eth0 exists');
	// Wait for address (default), setting is on system config
	if ($_SESSION['eth0chk'] == '1') {
		$eth0ip = waitForIpAddr('eth0', 3);
	}
	else {
		$eth0ip = sysCmd("ip addr list eth0 | grep \"inet \" |cut -d' ' -f6|cut -d/ -f1");
	}
}
else {
	$eth0ip = '';
	workerLog('worker: eth0 does not exist');
}
$logmsg = !empty($eth0ip[0]) ? 'eth0 (' . $eth0ip[0] . ')' : 'eth0 address not assigned';
workerLog('worker: ' . $logmsg);

// CHECK WLAN0
$wlan0ip = '';
$wlan0 = sysCmd('ip addr list | grep wlan0');
if (!empty($wlan0[0])) {
	workerLog('worker: wlan0 exists');
	$result = sdbquery('select * from cfg_network', $dbh);

	 // CASE: no ssid
	if (empty($result[1]['wlanssid']) || $result[1]['wlanssid'] == 'blank (activates AP mode)') {
		$ssidblank = true;
		workerLog('worker: wlan0 SSID is blank');
		// CASE: no eth0 addr
		if (empty($eth0ip[0])) {
			workerLog('worker: wlan0 AP mode started');
			$_SESSION['apactivated'] = true;
			activateApMode();
		}
		// CASE: eth0 addr exists
		else {
			workerLog('worker: eth0 addr exists, AP mode not started');
			$_SESSION['apactivated'] = false;
		}
	}
	// CASE: ssid exists
	else {
		workerLog('worker: wlan0 trying SSID (' . $result[1]['wlanssid'] . ')');
		$ssidblank = false;
		$_SESSION['apactivated'] = false;
	}

	// wait for ip address
	if ($_SESSION['apactivated'] == true || $ssidblank == false) {	
		$wlan0ip = waitForIpAddr('wlan0', 10);
		// CASE: ssid blank, ap mode activated 
		// CASE: ssid exists, ap mode fall back if no ip address after trying ssid
		if ($ssidblank == false) {
			if (empty($wlan0ip[0])) {
				workerLog('worker: wlan0 no IP addr for SSID (' . $result[1]['wlanssid'] . ')');
				if (empty($eth0ip[0])) {
					workerLog('worker: wlan0 AP mode started');
					$_SESSION['apactivated'] = true;
					activateApMode();
					$wlan0ip = waitForIpAddr('wlan0');
				}
				else {
					workerLog('worker: eth0 address exists so AP mode not started');
					$_SESSION['apactivated'] = false;
				}
			}
		}
	}

	$logmsg = !empty($wlan0ip[0]) ? 'wlan0 (' . $wlan0ip[0] . ')' : ($_SESSION['apactivated'] == true ? 'wlan0 unable to start AP mode' : 'wlan0 address not assigned');
	workerLog('worker: ' . $logmsg);

	// lets reset dhcpcd.conf in case a hard reboot or poweroff occurs
	resetApMode();
}
else {
	workerLog('worker: wlan0 does not exist' . ($_SESSION['wifibt'] == '0' ? ' (off)' : ''));
	$_SESSION['apactivated'] = false;
}

//
workerLog('worker: - Audio');
//

// ensure audio output is unmuted
if ($_SESSION['i2sdevice'] == 'IQaudIO Pi-AMP+') {	
	sysCmd('/var/www/command/util.sh unmute-pi-ampplus');
	workerLog('worker: IQaudIO Pi-AMP+ unmuted');
} else if ($_SESSION['i2sdevice'] == 'IQaudIO Pi-DigiAMP+') {	
	sysCmd('/var/www/command/util.sh unmute-pi-digiampplus');
	workerLog('worker: IQaudIO Pi-DigiAMP+ unmuted');
} else {
	sysCmd('/var/www/command/util.sh unmute-default');
	workerLog('worker: ALSA outputs unmuted');
}

// log device info
$logmsg = 'worker: ';
if ($_SESSION['i2sdevice'] == 'none') {
	$logmsg .= $_SESSION['cardnum'] == '1' ? 'Audio output (USB audio device)' : 'Audio output (On-board audio device)';
	workerLog($logmsg);
} else {
	workerLog($logmsg . 'Audio out (I2S audio device)');
	workerLog($logmsg . 'Audio dev (' . $_SESSION['i2sdevice'] . ')');
}

// store alsa mixer name for use by util.sh get/set-alsavol and vol.sh & .php
playerSession('write', 'amixname', getMixerName($_SESSION['i2sdevice']));
workerLog('worker: ALSA mixer name (' . $_SESSION['amixname'] . ')');
workerLog('worker: MPD volume control (' . $_SESSION['mpdmixer'] . ')');

// check for presence of hardware volume controller
$result = sysCmd('/var/www/command/util.sh get-alsavol ' . '"' . $_SESSION['amixname'] . '"');
if (substr($result[0], 0, 6 ) == 'amixer') {
	playerSession('write', 'alsavolume', 'none'); // hardware volume controller not detected
	workerLog('worker: Hdwr volume controller not detected');
} else {
	$result[0] = str_replace('%', '', $result[0]);
	playerSession('write', 'alsavolume', $result[0]); // volume level
	workerLog('worker: Hdwr volume controller exists');
}

// configure options for Burr Brown chips
$result = cfgdb_read('cfg_audiodev', $dbh, $_SESSION['i2sdevice']);
$chips = array('Burr Brown PCM5242','Burr Brown PCM5142','Burr Brown PCM5122','Burr Brown PCM5121','Burr Brown PCM5122 (PCM5121)','Burr Brown TAS5756');
if (in_array($result[0]['dacchip'], $chips) && $result[0]['chipoptions'] != '') {
	cfgChipOptions($result[0]['chipoptions']);
	workerLog('worker: Chip options (' . $result[0]['dacchip'] . ')');
}

// configure Piano 2.1
if ($_SESSION['i2sdevice'] == 'Allo Piano 2.1 Hi-Fi DAC') {
	$dualmode = sysCmd('/var/www/command/util.sh get-piano-dualmode');
	$submode = sysCmd('/var/www/command/util.sh get-piano-submode');
	// determine output mode
	if ($dualmode[0] != 'None') {
		$outputmode = $dualmode[0];
	}
	else {
		$outputmode = $submode[0];
	}
	// used in mpdcfg job and index.php
	$_SESSION['piano_dualmode'] = $dualmode[0];
	workerLog('worker: Piano output mode (' . $outputmode . ')');

	// WORKAROUND: bump one of the channels to init volume
	sysCmd('amixer -c0 sset "Digital" 0');
	sysCmd('speaker-test -c 2 -s 2 -r 48000 -F S16_LE -X -f 24000 -t sine -l 1');
	// reset Main vol back to 100% (0dB) if indicated
	if (($_SESSION['mpdmixer'] == 'software' || $_SESSION['mpdmixer'] == 'disabled') && $_SESSION['piano_dualmode'] != 'None') {
		sysCmd('amixer -c0 sset "Digital" 100%');
	}
	workerLog('worker: Piano 2.1 initialized');
}

//
workerLog('worker: - Services');
//

// start mpd
sysCmd("systemctl start mpd");
sleep(2);
workerLog('worker: MPD started');
workerLog('worker: MPD scheduler policy ' . '(' . ($_SESSION['mpdsched'] == 'other' ? 'time-share' : $_SESSION['mpdsched']) . ')');
// list mpd outputs, this covers the eq's
$sock = openMpdSock('localhost', 6600);
sendMpdCmd($sock, 'outputs');
$result = parseMpdOutputs(readMpdResp($sock));
workerLog('worker: ' . $result[0]);
workerLog('worker: ' . $result[1]);
workerLog('worker: ' . $result[2]);
workerLog('worker: ' . $result[3]);
// mpd crossfade
workerLog('worker: MPD crossfade (' . ($_SESSION['mpdcrossfade'] == '0' ? 'off' : $_SESSION['mpdcrossfade'] . ' secs')  . ')');

// FEATURES AVAILABILITY CONTROLLED BY FEAT_BITMASK

// start airplay receiver
if ($_SESSION['feat_bitmask'] & FEAT_AIRPLAY) {
	if (isset($_SESSION['airplaysvc']) && $_SESSION['airplaysvc'] == 1) {
		startSps();
		workerLog('worker: Airplay receiver started');
		workerLog('worker: Airplay volume mgt (' . $_SESSION['airplayvol'] . ')');
	}
}
else {
	workerLog('worker: Airplay receiver (feat N/A)');
}

// start squeezelite renderer
if ($_SESSION['feat_bitmask'] & FEAT_SQUEEZELITE) {
	if (isset($_SESSION['slsvc']) && $_SESSION['slsvc'] == 1) {
		cfgSqueezelite();
		startSqueezeLite();
		workerLog('worker: Squeezelite renderer started');
	} 
}
else {
	workerLog('worker: Squeezelite renderer (feat N/A)');
}

// start upnp renderer
if ($_SESSION['feat_bitmask'] & FEAT_UPMPDCLI) {
	if (isset($_SESSION['upnpsvc']) && $_SESSION['upnpsvc'] == 1) {
		sysCmd('systemctl start upmpdcli');
		workerLog('worker: UPnP renderer started');
	} 
}
else {
	workerLog('worker: UPnP renderer (feat N/A)');
}

// start minidlna
if ($_SESSION['feat_bitmask'] & FEAT_MINIDLNA) {
	if (isset($_SESSION['dlnasvc']) && $_SESSION['dlnasvc'] == 1) {
		startMiniDlna();
		workerLog('worker: DLNA server started');
	}
}
else {
	workerLog('worker: DLNA Server (feat N/A)');
}

// start audio scrobbler
if ($_SESSION['feat_bitmask'] & FEAT_MPDAS) {
	if (isset($_SESSION['mpdassvc']) && $_SESSION['mpdassvc'] == 1) {
		sysCmd('/usr/local/bin/mpdas > /dev/null 2>&1 &');
		workerLog('worker: Audio scrobbler started');
	} 
}
else {
	workerLog('worker: Audio scrobbler (feat N/A)');
}

// END FEATURES AVAILABILITY

// start rotary encoder
if (isset($_SESSION['rotaryenc']) && $_SESSION['rotaryenc'] == 1) {	
	sysCmd('systemctl start rotenc');
	workerLog('worker: Rotary encoder on (' . $_SESSION['rotenc_params'] . ')');
} 

// start lcd updater engine
if (isset($_SESSION['lcdup']) && $_SESSION['lcdup'] == 1) {
	startLcdUpdater();
	workerLog('worker: LCD updater engine started');
} 

// start shellinabox
if (isset($_SESSION['shellinabox']) && $_SESSION['shellinabox'] == 1) {
	sysCmd('systemctl start shellinabox');
	workerLog('worker: Shellinabox SSH server started');
} 

// start bluetooth controller
if (isset($_SESSION['btsvc']) && $_SESSION['btsvc'] == 1) {
	workerLog('worker: Bluetooth controller started');
	startBt();
}

//
workerLog('worker: - Last');
//

// list usb sources
$result = sysCmd('ls /media');
$logmsg = $result[0] == '' ? 'none attached' : $result[0];
workerLog('worker: USB sources ' . '(' . $logmsg . ')');

// mount nas sources
workerLog('worker: NAS sources (mountall initiated)');
$result = wrk_sourcemount('mountall');

// restore volume level
sysCmd('/var/www/vol.sh ' . $_SESSION['volknob']);
workerLog('worker: Volume level (' . $_SESSION['volknob'] . ') restored');

// auto-play last played item if indicated
if ($_SESSION['autoplay'] == '1') {
	$status = parseStatus(getMpdStatus($sock));
	sendMpdCmd($sock, 'playid ' . $status['songid']);
	$resp = readMpdResp($sock);
	workerLog('worker: Auto-playing id (' . $status['songid'] . ')');
}
else {
	sendMpdCmd($sock, 'stop');
	$resp = readMpdResp($sock);
}
closeMpdSock($sock);

// start auto-shuffle
if ($_SESSION['ashuffle'] == '1') {
	sysCmd('/usr/local/bin/ashuffle > /dev/null 2>&1 &');
	workerLog('worker: Auto-shuffle started');
}

// clock radio globals
$ckstart = $_SESSION['ckradstart'];
$ckstop = $_SESSION['ckradstop'];

// maintenance interval global
$maint_interval = $_SESSION['maint_interval'];
workerLog('worker: Maintenance interval (' . $_SESSION['maint_interval'] . ')');

// start watchdog monitor
sysCmd('/var/www/command/watchdog.sh > /dev/null 2>&1 &');
workerLog('worker: Watchdog started');

// inizialize worker job queue
$_SESSION['w_queue'] = '';
$_SESSION['w_queueargs'] = '';
$_SESSION['w_lock'] = 0;
$_SESSION['w_active'] = 0;

// close session
session_write_close();

//
workerLog('worker: Ready');
//

// run the ready script
sysCmd('/var/local/www/commandw/wrkready.sh > /dev/null 2>&1 &');

//
// BEGIN WORKER JOB LOOP
//

while (1) {
	sleep(3);
		
	session_start();

	if ($_SESSION['maint_interval'] != 0) {
		chkMaintenance($maint_interval);
	}

	// Experimental: for usb hot-plug
	if ($_SESSION['cardnum'] == '1') {
		sysCmd('alsactl store');
	}

	if ($_SESSION['extmeta'] == '1') {
		updExtMetaFile();
	}

 	if ($_SESSION['ckrad'] == 'Clock Radio') {
		chkClockRadio();		
	}

 	if ($_SESSION['ckrad'] == 'Sleep Timer') {
		chkSleepTimer();		
	}

	if ($_SESSION['playhist'] == 'Yes') {
		updPlayHistory();		
	}

	if ($_SESSION['w_active'] == 1 && $_SESSION['w_lock'] == 0) {
		runQueuedJob();
	}

	session_write_close();	
}

// worker functions

function chkMaintenance($maint_interval) {
	$maint_interval = $maint_interval - 3;
	if ($maint_interval <= 0) {
		sysCmd('/var/local/www/commandw/maint.sh');		
		$GLOBALS['maint_interval'] = $_SESSION['maint_interval'];
		workerLog('worker: Maintenance completed');
	}
	else {
		$GLOBALS['maint_interval'] = $maint_interval;
	}
}

function updExtMetaFile() {
	// current metadata
	$sock = openMpdSock('localhost', 6600);
	$current = parseStatus(getMpdStatus($sock));
	$current = enhanceMetadata($current, $sock, 'nomediainfo');
	closeMpdSock($sock);

	// file  metadata
	$filemeta = parseDelimFile(file_get_contents('/var/local/www/currentsong.txt'), '=');

	// write metadata to file for external applications
	if ($current['title'] != $filemeta['title'] || $current['album'] != $filemeta['album'] || $_SESSION['volknob'] != $filemeta['volume'] || 
		$_SESSION['volmute'] != $filemeta['mute'] || $current['state'] != $filemeta['state']) {	

		$fh = fopen('/var/local/www/currentsong.txt', 'w') or exit('file open failed on /var/local/www/currentsong.txt');
		// default 
		$data = 'file=' . $current['file'] . "\n"; 
		$data .= 'artist=' . $current['artist'] . "\n";
		$data .= 'album=' . $current['album'] . "\n";
		$data .= 'title=' . $current['title'] . "\n";
		$data .= 'coverurl=' . $current['coverurl'] . "\n";
		// xtra tags
		$data .= 'track=' . $current['track'] . "\n";
		$data .= 'date=' . $current['date'] . "\n";
		$data .= 'composer=' . $current['composer'] . "\n";
		// other
		$data .= 'encoded=' . getEncodedAt($current, 'default') . "\n";
		$data .= 'bitrate=' . $current['bitrate'] . "\n";
		$data .= 'volume=' . $_SESSION['volknob'] . "\n";
		$data .= 'mute=' . $_SESSION['volmute'] . "\n";
		$data .= 'state=' . $current['state'] . "\n";
		
		fwrite($fh, $data);
		fclose($fh);
	}
}

function chkClockRadio() {
	$curtime = date("hi A");
	$retrystop = 2;
	
	if ($curtime == $GLOBALS['ckstart']) {
		$GLOBALS['ckstart'] = ''; // reset so this section is only done once
		$sock = openMpdSock('localhost', 6600);

		// find playlist item
		sendMpdCmd($sock, 'playlistfind file ' . '"' . $_SESSION['ckraditem'] . '"');
		$resp = readMpdResp($sock);
		$array = array();
		$line = strtok($resp, "\n");
		while ($line) {
			list($element, $value) = explode(': ', $line, 2);
			$array[$element] = $value;
			$line = strtok("\n");
		} 

		// send play cmd
		sendMpdCmd($sock, 'play ' . $array['Pos']);
		$resp = readMpdResp($sock);
		closeMpdSock($sock);
		
		// set volume
		sysCmd('/var/www/vol.sh ' . $_SESSION['ckradvol']);
		
	}
	else if ($curtime == $GLOBALS['ckstop']) {
		debugLog('chkClockRadio(): stoptime=(' . $GLOBALS['ckstop'] . ')');
		$GLOBALS['ckstop'] = '';  // reset so this section is only done once
		$sock = openMpdSock('localhost', 6600);

		// send several stop commands for robustness
		while ($retrystop > 0) {
			sendMpdCmd($sock, 'stop');
			$resp = readMpdResp($sock);
			usleep(250000);
			--$retrystop;
		}
		closeMpdSock($sock);
		debugLog('chkClockRadio(): $curtime=(' . $curtime . ')');
		debugLog('chkClockRadio(): stop command sent');

		// shutdown if requested
		if ($_SESSION['ckradshutdn'] == "Yes") {
			sysCmd('/var/local/www/commandw/restart.sh poweroff');
		}
	}

	// reload globals
	if ($curtime != $_SESSION['ckradstart'] && $GLOBALS['ckstart'] == '') {
		$GLOBALS['ckstart'] = $_SESSION['ckradstart'];
		debugLog('chkClockRadio(): starttime global reloaded');
	}

	if ($curtime != $_SESSION['ckradstop'] && $GLOBALS['ckstop'] == '') {
		$GLOBALS['ckstop'] = $_SESSION['ckradstop'];
		debugLog('chkClockRadio(): stoptime global reloaded');
	}
}

function chkSleepTimer() {
	$curtime = date("hi A");
	$retrystop = 2;
	
	if ($curtime == $GLOBALS['ckstop']) {
		debugLog('chkSleepTimer(): stoptime=(' . $GLOBALS['ckstop'] . ')');
		$GLOBALS['ckstop'] = '';  // reset so this section is only done once
		$sock = openMpdSock('localhost', 6600);

		// send several stop commands for robustness
		while ($retrystop > 0) {
			sendMpdCmd($sock, 'stop');
			$resp = readMpdResp($sock);
			usleep(250000);
			--$retrystop;
		}

		sendMpdCmd($sock, 'stop');
		$resp = readMpdResp($sock);
		closeMpdSock($sock);
		debugLog('chkSleepTimer(): $curtime=(' . $curtime . ')');
		debugLog('chkSleepTimer(): stop command sent');

		// shutdown if requested
		if ($_SESSION['ckradshutdn'] == "Yes") {
			sysCmd('/var/local/www/commandw/restart.sh poweroff');
		}
	}

	// reload global
	if ($curtime != $_SESSION['ckradstop'] && $GLOBALS['ckstop'] == '') {
		$GLOBALS['ckstop'] = $_SESSION['ckradstop'];
		debugLog('chkSleepTimer(): stoptime global reloaded');
	}
}

function updPlayHistory() {
	$sock = openMpdSock('localhost', 6600);
	$song = parseCurrentSong($sock);
	closeMpdSock($sock);
	
	// itunes aac file
	if (isset($song['Name']) && getFileExt($song['file']) == 'm4a') {
		$artist = isset($song['Artist']) ? $song['Artist'] : 'Unknown artist';
		$title = $song['Name']; 
		$album = isset($song['Album']) ? $song['Album'] : 'Unknown album';
		
		// search string
		if ($artist == 'Unknown artist' && $album == 'Unknown album') {$searchstr = $title;}
		else if ($artist == 'Unknown artist') {$searchstr = $album . '+' . $title;}
		else if ($album == 'Unknown album') {$searchstr = $artist . '+' . $title;}
		else {$searchstr = $artist . '+' . $album;}

	// radio station
	} else if (isset($song['Name']) || (substr($song['file'], 0, 4) == 'http' && !isset($song['Artist']))) {
		$artist = 'Radio station';

		if (!isset($song['Title']) || trim($song['Title']) == '') {
			$title = $song['file'];
		} else {
			// use custom name if indicated
			$title = $_SESSION[$song['file']]['name'] == 'Classic And Jazz' ? 'CLASSIC & JAZZ (Paris - France)' : $song['Title'];
		}
		
		if (isset($_SESSION[$song['file']])) {
			$album = $_SESSION[$song['file']]['name'];
		} else {
			$album = isset($song['Name']) ? $song['Name'] : 'Unknown station';
		}
		
		// search string
		if ($title != 'Streaming source') {
			$searchstr = str_replace('-', ' ', $title);
			$searchstr = str_replace('&', ' ', $searchstr);
			$searchstr = preg_replace('!\s+!', '+', $searchstr);
		}
		
	// song file or upnp url	
	} else {
		$artist = isset($song['Artist']) ? $song['Artist'] : 'Unknown artist';
		$title = isset($song['Title']) ? $song['Title'] : pathinfo(basename($song['file']), PATHINFO_FILENAME);
		$album = isset($song['Album']) ? $song['Album'] : 'Unknown album';

		// search string
		if ($artist == 'Unknown artist' && $album == 'Unknown album') {$searchstr = $title;}
		else if ($artist == 'Unknown artist') {$searchstr = $album . '+' . $title;}
		else if ($album == 'Unknown album') {$searchstr = $artist . '+' . $title;}
		else {$searchstr = $artist . '+' . $album;}
	}

	// search url
	if ($title == 'Streaming source') {
		$searchurl = '<span class="playhistory-link"><i class="icon-external-link"></i></span>';
	} else {
		$searcheng = 'http://www.google.com/search?q=';
		$searchurl = '<a href="' . $searcheng . $searchstr . '" class="playhistory-link" target="_blank"><i class="icon-external-link-sign"></i></a>';
	}
	
	// update playback history log
	if ($title != '' && $title != $_SESSION['phistsong']) {
		$_SESSION['phistsong'] = $title; // store title as-is
		cfgdb_update('cfg_system', cfgdb_connect(), 'phistsong', str_replace("'", "''", $title)); // write to cfg db using sql escaped single quotes

		$historyitem = '<li class="playhistory-item"><div>' . date('Y-m-d H:i') . $searchurl . $title . '</div><span>' . $artist . ' - ' . $album . '</span></li>';
		$result = updPlayHist($historyitem);
	}
}

function runQueuedJob() {
	$_SESSION['w_lock'] = 1;
	workerLog('worker: Job ' . $_SESSION['w_queue']);
	
	switch($_SESSION['w_queue']) {
		// src-config jobs
		case 'updmpddb':
		case 'rescanmpddb':
			// clear libcache
			sysCmd('truncate /var/local/www/libcache.json --size 0');
			// db update / rescan
			$sock = openMpdSock('localhost', 6600);
			$cmd = $_SESSION['w_queue'] == 'updmpddb' ? 'update' : 'rescan';
			sendMpdCmd($sock, $cmd);
			$resp = readMpdResp($sock);
			closeMpdSock($sock);
			break;
		case 'sourcecfg':
			// clear libcache
			sysCmd('truncate /var/local/www/libcache.json --size 0');
			// update cfg_source and do the mounts, waitworker() handles the db update
			wrk_sourcecfg($_SESSION['w_queueargs']);
			break;
		
		// mpd-config jobs
		case 'mpdrestart':
			sysCmd('mpc stop');
			sysCmd('systemctl restart mpd');
			break;
		case 'mpdcfg':
			// stop playback
			sysCmd('mpc stop');
			
			// update config file
			wrk_mpdconf($_SESSION['i2sdevice']);

			// set hardware volume to 0dB (100) if mpd software or disabled and hdwr vol controller exists
			if (($_SESSION['mpdmixer'] == 'software' || $_SESSION['mpdmixer'] == 'disabled') && $_SESSION['alsavolume'] != 'none') {
				sysCmd('/var/www/command/util.sh set-alsavol ' . '"' . $_SESSION['amixname']  . '"' . ' 100');
			}

			// restart mpd and pick up conf changes
			sysCmd('systemctl restart mpd');

			// wait for mpd to start accepting connections
			$sock = openMpdSock('localhost', 6600);
			closeMpdSock($sock);

			// set knob and mpd/hardware volume to 0
			sysCmd('/var/www/vol.sh 0');

			// TEST for usb hot-plug
			if ($_SESSION['cardnum'] == '1') {
				sysCmd('alsactl store');
			}

			// restart renderers if device num changed
			if ($_SESSION['w_queueargs'] == 'devicechg' && $_SESSION['airplaysvc'] == 1) {
				sysCmd('killall shairport-sync');
				sysCmd('rm /tmp/shairport-sync-metadata');
				startSps();
			}
			break;

		// squeezelite jobs
		case 'slsvc':
			if ($_SESSION['slsvc'] == '1') {
				sysCmd('mpc stop');
				if ($_SESSION['alsavolume'] != 'none') {
					sysCmd('/var/www/command/util.sh set-alsavol ' . '"' . $_SESSION['amixname']  . '"' . ' 100');
				}
				
				cfgSqueezelite();
				startSqueezeLite();
			}
			else {
				sysCmd('killall -s 9 squeezelite');
				sysCmd('/var/www/vol.sh restore');
			}
			break;
		case 'slrestart':
			if ($_SESSION['slsvc'] == '1') {
				startSqueezeLite();
			}
			break;
		case 'slcfgupdate':
			cfgSqueezelite();
			if ($_SESSION['slsvc'] == '1') {
				startSqueezeLite();
			}
			break;
			
		// net-config jobs
		case 'netcfg':
			cfgNetIfaces();
			resetApMode();
			cfgHostApd();
			break;

		// snd-config jobs
		case 'i2sdevice':
			cfgI2sOverlay($_SESSION['w_queueargs']);
			break;
		case 'alsavolume':
			$mixername = getMixerName($_SESSION['i2sdevice']);
			sysCmd('/var/www/command/util.sh set-alsavol ' . '"' . $mixername  . '"' . ' ' . $_SESSION['w_queueargs']);
			break;
		case 'rotaryenc':
			sysCmd('systemctl stop rotenc');
			sysCmd('sed -i "/ExecStart/c\ExecStart=' . '/usr/local/bin/rotenc ' . $_SESSION['rotenc_params'] . '"' . ' /lib/systemd/system/rotenc.service');
			sysCmd('systemctl daemon-reload');

			if ($_SESSION['w_queueargs'] == '1') {
				sysCmd('systemctl start rotenc');
			}			
			break;
		case 'crossfeed':
			sysCmd('mpc stop');

			if ($_SESSION['w_queueargs'] == 'Off') {
				sysCmd('mpc enable only 1');
			}
			else {
				sysCmd('sed -i "/controls/c\ \t\t\tcontrols [ ' . $_SESSION['w_queueargs'] . ' ]"' . ' /usr/share/alsa/alsa.conf.d/crossfeed.conf');
				sysCmd('mpc enable only 2');
			}
			break;
		case 'eqfa4p':
			// old,new curve name
			$setting = explode(',', $_SESSION['w_queueargs']);

			if ($setting[1] == 'Off') {
				sysCmd('mpc stop');
				sysCmd('mpc enable only 1');
			}
			else {
				// check old curve name and stop playback if eq being turned on for first time
				if ($setting[0] == 'Off') {
					sysCmd('mpc stop');
				}

				$result = sdbquery("select * from cfg_eqfa4p where curve_name='" . $setting[1] . "'", cfgdb_connect());
				$params = $result[0]['band1_params'] . '  ' . $result[0]['band2_params'] . '  ' . $result[0]['band3_params'] . '  ' . $result[0]['band4_params'] . '  ' . $result[0]['master_gain'];

				sysCmd('sed -i "/controls/c\ \t\t\tcontrols [ ' . $params . ' ]"' . ' /usr/share/alsa/alsa.conf.d/eqfa4p.conf');
				sysCmd('mpc enable only 3');
			}

			sysCmd('systemctl restart mpd');
			break; 
		case 'alsaequal':
			// old,new curve name
			$setting = explode(',', $_SESSION['w_queueargs']);

			if ($setting[1] == 'Off') {
				sysCmd('mpc stop');
				sysCmd('mpc enable only 1');
			}
			else {
				// check old curve name and stop playback if eq being turned on for first time
				if ($setting[0] == 'Off') {
					sysCmd('mpc stop');
				}

				$result = sdbquery("SELECT curve_values FROM cfg_eqalsa WHERE curve_name='" . $setting[1] . "'", cfgdb_connect());
				$curve = explode(',', $result[0]['curve_values']);
				foreach ($curve as $key => $value) {
					sysCmd('amixer -D alsaequal cset numid=' . ($key + 1) . ' ' . $value);
				}
				sysCmd('mpc enable only 4');
			}
			break; 
		case 'mpdassvc':
			sysCmd('killall -s 9 mpdas > /dev/null');
			cfgAudioScrobbler();
			if ($_SESSION['w_queueargs'] == 1) {
				sysCmd('/usr/local/bin/mpdas > /dev/null 2>&1 &');
			}
			break;
		case 'mpdcrossfade':
			sysCmd('mpc crossfade ' . $_SESSION['w_queueargs']);
			break;
		case 'airplaysvc':
			sysCmd('killall shairport-sync');
			sysCmd('rm /tmp/shairport-sync-metadata');
			playerSession('write', 'airplayactv', '0');
			if ($_SESSION['airplaysvc'] == 1) {startSps();}
			break;
		case 'btsvc':
			sysCmd('/var/www/command/util.sh chg-name bluetooth ' . $_SESSION['w_queueargs']);
			sysCmd('systemctl stop bluealsa');
			sysCmd('systemctl stop bluetooth');
			sysCmd('systemctl stop hciuart');
			sysCmd('killall bluealsa-aplay');
			if ($_SESSION['btsvc'] == 1) {startBt();}
			break;
		case 'btmulti':
			if ($_SESSION['btmulti'] == 1) {
				sysCmd("sed -i '/AUDIODEV/c\AUDIODEV=btaplay_dmix' /etc/bluealsaaplay.conf");				
			}
			else {
				sysCmd("sed -i '/AUDIODEV/c\AUDIODEV=hw:" . $_SESSION['cardnum'] . ",0' /etc/bluealsaaplay.conf");				
			}		
			break;
		case 'upnpsvc':
			sysCmd('/var/www/command/util.sh chg-name upnp ' . $_SESSION['w_queueargs']);
			sysCmd('systemctl stop upmpdcli');
			if ($_SESSION['upnpsvc'] == 1) {sysCmd('systemctl start upmpdcli');}
			break;
		case 'minidlna':
			sysCmd('/var/www/command/util.sh chg-name dlna ' . $_SESSION['w_queueargs']);
			sysCmd('systemctl stop minidlna');
			if ($_SESSION['dlnasvc'] == 1) {
				startMiniDlna();
			} else {
				syscmd('rm -rf /var/cache/minidlna/* > /dev/null');
				sysCmd('umount /mnt/UPNP > /dev/null 2>&1 &');
			}
			break;
		case 'dlnarebuild':
			sysCmd('systemctl stop minidlna');
			syscmd('rm -rf /var/cache/minidlna/* > /dev/null');
			sysCmd('umount /mnt/UPNP > /dev/null');
			sleep(2);
			startMiniDlna();
			break;

		// sys-config jobs
		case 'installupd':
			sysCmd('/var/www/command/updater.sh ' . getPkgId() . ' > /dev/null 2>&1');
			break;
		case 'timezone':
			sysCmd('/var/www/command/util.sh set-timezone ' . $_SESSION['w_queueargs']);
			break;
		case 'hostname':
			sysCmd('/var/www/command/util.sh chg-name host ' . $_SESSION['w_queueargs']);
			break;
		case 'browsertitle':
			sysCmd('/var/www/command/util.sh chg-name browsertitle ' . $_SESSION['w_queueargs']);
			break;
		case 'cpugov':
			sysCmd('sh -c ' . "'" . 'echo "' . $_SESSION['w_queueargs'] . '" | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor' . "'");
			break;
		case 'p3wifi':
			ctlWifi($_SESSION['w_queueargs']);
			break;
		case 'p3bt':
			ctlBt($_SESSION['w_queueargs']);
			break;
		case 'hdmiport':
			$cmd = $_SESSION['w_queueargs'] == '1' ? 'tvservice -p' : 'tvservice -o';
			sysCmd($cmd . ' > /dev/null');
			break;
		case 'maxusbcurrent':
			$cmd = $_SESSION['w_queueargs'] == 1 ? 'echo max_usb_current=1 >> ' . $_SESSION['res_boot_config_txt'] : 'sed -i /max_usb_current/d ' . $_SESSION['res_boot_config_txt'];
			sysCmd($cmd);
			break;
		case 'uac2fix':
			if ($_SESSION['w_queueargs'] == 1) {
				sysCmd('sed -i "s/dwc_otg.lpm_enable=0/dwc_otg.lpm_enable=0 dwc_otg.fiq_fsm_mask=0x3/" /boot/cmdline.txt');
			}
			else {
				sysCmd('sed -i "s/ dwc_otg.fiq_fsm_mask=0x3//" /boot/cmdline.txt');
			}
			break;
		case 'expandrootfs':
			sysCmd('/var/www/command/resizefs.sh start');
			sleep(3); // so message appears on sys-config screen before reboot happens
			sysCmd('mpc stop && reboot');
			break;
		case 'usbboot':
			sysCmd('sed -i /program_usb_boot_mode/d ' . $_SESSION['res_boot_config_txt']); // remove first to prevent duplicate adds
			sysCmd('echo program_usb_boot_mode=1 >> ' . $_SESSION['res_boot_config_txt']);
			break;
		case 'localui':
			sysCmd('sudo systemctl ' . ($_SESSION['w_queueargs'] == '1' ? 'enable' : 'disable') . ' localui');
			sysCmd('sudo systemctl ' . ($_SESSION['w_queueargs'] == '1' ? 'start' : 'stop') . ' localui');
			break;
		case 'touchscn':
			$param = $_SESSION['w_queueargs'] == '1' ? ' -- -nocursor' : '';
			sysCmd('sed -i "/ExecStart=/c\ExecStart=/usr/bin/xinit' .$param . '" /lib/systemd/system/localui.service');
			if ($_SESSION['localui'] == '1') {
				sysCmd('systemctl daemon-reload');
				sysCmd('systemctl restart localui');
			}
			break;
		case 'scnblank':
			sysCmd('sed -i "/xset s/c\xset s ' . $_SESSION['w_queueargs'] . '" /home/pi/.xinitrc');
			if ($_SESSION['localui'] == '1') {
				sysCmd('systemctl restart localui');
			}
		case 'scnbrightness':
			sysCmd('/bin/su -c "echo '. $_SESSION['w_queueargs'] . ' > /sys/class/backlight/rpi_backlight/brightness"');
		case 'scnrotate':
			sysCmd('sed -i /lcd_rotate/d ' . $_SESSION['res_boot_config_txt']);
			if ($_SESSION['w_queueargs'] == '180') {
				sysCmd('echo lcd_rotate=2 >> ' . $_SESSION['res_boot_config_txt']);
			}
			break;
		case 'keyboard':
			sysCmd('/var/www/command/util.sh set-keyboard ' . $_SESSION['w_queueargs']);
			break;
		case 'lcdup':
			$_SESSION['w_queueargs'] == 1 ? startLcdUpdater() : sysCmd('killall inotifywait > /dev/null 2>&1 &');
			break;
		case 'shellinabox':
			sysCmd('systemctl stop shellinabox');
			if ($_SESSION['w_queueargs'] == '1') {
				sysCmd('systemctl start shellinabox');
			}
			break;
		case 'clearsyslogs':
			sysCmd('/var/www/command/util.sh clear-syslogs');
			break;
		case 'clearplayhistory':
			sysCmd('/var/www/command/util.sh clear-playhistory');
			break;
		case 'compactdb':
			sysCmd('sqlite3 /var/local/www/db/moode-sqlite3.db "vacuum"');
			break;
		case 'nettime': // not working...
			sysCmd('systemctl stop ntp');
			sysCmd('ntpd -qgx > /dev/null 2>&1 &');
			sysCmd('systemctl start ntp');
			break;

		// audio input output config jobs
		case 'audioout':
			if ($_SESSION['w_queueargs'] == 'Local') {
				sysCmd('mpc stop');
				sysCmd('mpc enable only 1');
			}
			else if ($_SESSION['w_queueargs'] == 'Bluetooth') {
				sysCmd('mpc stop');
				sysCmd('mpc enable only 5');
			}
			sysCmd('systemctl restart mpd');
			break; 

		case 'audioin':
			if ($_SESSION['w_queueargs'] == 'Local') {
				sysCmd('mpc stop');
			}
			else if ($_SESSION['w_queueargs'] == 'Analog') {
				sysCmd('mpc stop');
				// send cmd to switch input
			}
			else if ($_SESSION['w_queueargs'] == 'S/PDIF') {
				sysCmd('mpc stop');
				// send cmd to switch input
			}
			break; 

		// command/moode jobs
		case 'setbgimage':
			$imgdata = base64_decode($_SESSION['w_queueargs'], true);
			if ($imgdata === false) {
				workerLog('worker: setbgimage: base64_decode failed');
			}
			else {
				$fh = fopen('/var/local/www/imagesw/bgimage.jpg', 'w');
				fwrite($fh, $imgdata);
				fclose($fh);
			}
			break;
		case 'reboot':
		case 'poweroff':
			resetApMode();
			sysCmd('/var/local/www/commandw/restart.sh ' . $_SESSION['w_queue']);
			break;
		case 'reloadclockradio':
			$GLOBALS['ckstart'] = $_SESSION['ckradstart'];
			$GLOBALS['ckstop'] = $_SESSION['ckradstop'];
			break;
		case 'alizarin': // hex color: #c0392b, rgba 192,57,43,0.71
			sysCmd('/var/www/command/util.sh alizarin'); // don't specify colors, this is the default
			break;
		case 'amethyst':
			sysCmd('/var/www/command/util.sh amethyst 8e44ad "rgba(142,68,173,0.71)"');
			break;
		case 'bluejeans':
			sysCmd('/var/www/command/util.sh bluejeans 1a439c "rgba(26,67,156,0.71)"');
			break;
		case 'carrot':
			sysCmd('/var/www/command/util.sh carrot d35400 "rgba(211,84,0,0.71)"');
			break;
		case 'emerald':
			sysCmd('/var/www/command/util.sh emerald 27ae60 "rgba(39,174,96,0.71)"');
			break;
		case 'fallenleaf':
			sysCmd('/var/www/command/util.sh fallenleaf cb8c3e "rgba(203,140,62,0.71)"');
			break;
		case 'grass':
			sysCmd('/var/www/command/util.sh grass 7ead49 "rgba(126,173,73,0.71)"');
			break;
		case 'herb':
			sysCmd('/var/www/command/util.sh herb 317589 "rgba(49,117,137,0.71)"');
			break;
		case 'lavender':
			sysCmd('/var/www/command/util.sh lavender 876dc6 "rgba(135,109,198,0.71)"');
			break;
		case 'river':
			sysCmd('/var/www/command/util.sh river 2980b9 "rgba(41,128,185,0.71)"');
			break;
		case 'rose':
			sysCmd('/var/www/command/util.sh rose c1649b "rgba(193,100,155,0.71)"');
			break;
		case 'silver':
			sysCmd('/var/www/command/util.sh silver 999999 "rgba(153,153,153,0.71)"');
			break;
		case 'turquoise':
			sysCmd('/var/www/command/util.sh turquoise 16a085 "rgba(22,160,133,0.71)"');
			break;
	}
	
	// reset job queue
	$_SESSION['w_queue'] = '';
	$_SESSION['w_queueargs'] = '';
	$_SESSION['w_lock'] = 0;
	$_SESSION['w_active'] = 0;
}
