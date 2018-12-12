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
 * 2018-04-02 TC moOde 4.1
 * - substantial rewrite
 * 2018-07-11 TC moOde 4.2
 * - add trim() to Name validation
 * - remove sec=ntlm from default mount flags
 * - handle auto db update here iunstead of in waitWirker();
 * - font-awesome 5
 * 2018-09-27 TC moOde 4.3
 * - thumbnail cache
 * 2018-10-19 TC moOde 4.3 update
 * - setting for auto-update DB on USB insert/remove
 *
 */

require_once dirname(__FILE__) . '/inc/playerlib.php';

if (false === ($sock = openMpdSock('localhost', 6600))) {
	$msg = 'src-config: Connection to MPD failed'; 
	workerLog($msg);
	exit($msg . "\n");
}
else {
	playerSession('open', '' ,''); 
	$dbh = cfgdb_connect();
	session_write_close();
}

// for save/remove actions
$initiateDBUpd = false;

// SOURCE CONFIG POSTS

// update mpd database
if (isset($_POST['updatempd'])) {
	submitJob('updmpddb', '', 'DB update initiated...', '');
}
// rescan mpd database
if (isset($_POST['rescanmpd'])) {
	submitJob('rescanmpddb', '', 'DB rescan initiated...', '');
}
// r44a auto-update mpd db on usb insert/remove
if (isset($_POST['update_usb_auto_updatedb'])) {
	if (isset($_POST['usb_auto_updatedb']) && $_POST['usb_auto_updatedb'] != $_SESSION['usb_auto_updatedb']) {
		$_SESSION['notify']['title'] = $_POST['usb_auto_updatedb'] == '1' ? 'MPD auto-update on' : 'MPD auto-update off';
		$_SESSION['notify']['duration'] = 3;
		playerSession('write', 'usb_auto_updatedb', $_POST['usb_auto_updatedb']);
	}
}
// re-mount nas sources
if (isset($_POST['remount'])) {
	$result_unmount = wrk_sourcemount('unmountall');
	$result_mount = wrk_sourcemount('mountall');
	//workerLog('src-config: remount: (' . $result_unmount . ', ' . $result_mount . ')');
	$_SESSION['notify']['title'] = 'Re-mount initiated...';
}
// reset library cache
if (isset($_POST['clrtagcache'])) {
	sysCmd('truncate ' . LIBCACHE_JSON . ' --size 0');
	$_SESSION['notify']['title'] = 'Tag cache cleared';
	$_SESSION['notify']['msg'] = 'Open the Library to regenerate it';
}
// update thumbnail cache
if (isset($_POST['updthmcache'])) {
	$result = sysCmd('pgrep -l thmcache.php');
	if (strpos($result[0], 'thmcache.php') !== false) {
		$_SESSION['notify']['title'] = 'Process is currently running';
	}
	else {
		$_SESSION['thmcache_status'] = 'Updating thumbnail cache...';
		submitJob('updthmcache', '', 'Updating thumbnail cache...', '');
	}
}
// regenerate thumbnail cache
if (isset($_POST['regenthmcache'])) {
	$result = sysCmd('pgrep -l thmcache.php');
	if (strpos($result[0], 'thmcache.php') !== false) {
		$_SESSION['notify']['title'] = 'Process is currently running';
	}
	else {
		$_SESSION['thmcache_status'] = 'Regenerating thumbnail cache...';
		submitJob('regenthmcache', '', 'Regenerating thumbnail cache...', '');
	}
}

// NAS CONFIG POSTS

// remove nas source
if (isset($_POST['delete']) && $_POST['delete'] == 1) {
	$initiateDBUpd = true;
	$_POST['mount']['action'] = 'delete';
	submitJob('sourcecfg', $_POST, 'NAS source removed', 'DB update initiated...');
}
// save nas source
if (isset($_POST['save']) && $_POST['save'] == 1) {
	// validate 
	$id = sdbquery("SELECT id from cfg_source WHERE name='" . $_POST['mount']['name'] . "'", $dbh);
	$name = strtolower($_POST['mount']['name']);
	$address = explode('/', $_POST['mount']['address'], 2);
	$_POST['mount']['address'] = $address[0];
	$_POST['mount']['remotedir'] = $address[1];

	// server	
	if (empty(trim($_POST['mount']['address']))) {
		$_SESSION['notify']['title'] = 'Server cannot be blank';
		$_SESSION['notify']['duration'] = 20;
	}
	// share
	elseif (empty(trim($_POST['mount']['remotedir']))) {
		$_SESSION['notify']['title'] = 'Share cannot be blank';
		$_SESSION['notify']['duration'] = 20;
	}
	// userid
	elseif ($_POST['mount'] == 'cifs' && empty(trim($_POST['mount']['username']))) {
		$_SESSION['notify']['title'] = 'Userid cannot be blank';
		$_SESSION['notify']['duration'] = 20;
	}
	// name
	elseif ($_POST['mount']['action'] == 'add' && !empty($id[0])) {
		$_SESSION['notify']['title'] = 'Name already exists';
		$_SESSION['notify']['duration'] = 20;
	}
	elseif (trim(empty($_POST['mount']['name']))) {
		$_SESSION['notify']['title'] = 'Name cannot be blank';
		$_SESSION['notify']['duration'] = 20;
	}
	elseif (strpos($name, 'nas') !== false || strpos($name, 'radio') !== false ||strpos($name, 'sdcard') !== false) {
		$_SESSION['notify']['title'] = 'Name cannot contain NAS, RADIO, or SDCARD';
		$_SESSION['notify']['duration'] = 20;
	}
	// ok so save
	else {
		$initiateDBUpd = true;
		// defaults
		if (empty(trim($_POST['mount']['rsize']))) {$_POST['mount']['rsize'] = 61440;}
		if (empty(trim($_POST['mount']['wsize']))) {$_POST['mount']['wsize'] = 65536;}
		if (empty(trim($_POST['mount']['options']))) {
			if ($_POST['mount']['type'] == 'cifs') {
				$_POST['mount']['options'] = "vers=1.0,ro,dir_mode=0777,file_mode=0777";
			}
			else {
				$_POST['mount']['options'] = "ro,nolock";
			}
		}
		
		// $array['mount']['key'] must be in column order for subsequent table insert
		// table cols = id, name, type, address, remotedir, username, password, charset, rsize, wsize, options, error
		// new id is auto generated, action = add, edit, delete
		$array['mount']['action'] = $_POST['mount']['action'];
		$array['mount']['id'] = $_POST['mount']['id'];
		$array['mount']['name'] = $_POST['mount']['name'];
		$array['mount']['type'] = $_POST['mount']['type'];
		$array['mount']['address'] = $_POST['mount']['address'];
		$array['mount']['remotedir'] = $_POST['mount']['remotedir'];
		$array['mount']['username'] = $_POST['mount']['username'];
		$array['mount']['password'] = $_POST['mount']['password'];
		$array['mount']['charset'] = $_POST['mount']['charset'];
		$array['mount']['rsize'] = $_POST['mount']['rsize'];
		$array['mount']['wsize'] = $_POST['mount']['wsize'];
		$array['mount']['options'] = $_POST['mount']['options'];

		submitJob('sourcecfg', $array, 'NAS config saved', 'DB update initiated...');
	}
}
// samba scanner
if (isset($_POST['scan']) && $_POST['scan'] == 1) {
	$_GET['cmd'] = $_SESSION['nas_action'];
	$_GET['id'] = $_SESSION['nas_mpid'];

	// generate scan
	$result = sysCmd('smbtree -N -b');
	sort($result, SORT_NATURAL | SORT_FLAG_CASE);

	// parse scan results
	foreach ($result as $line) {
		if (strpos(strtolower($line), 'ipc$') === false && 
			strpos($line, 'WORKGROUP') === false) {

			// flatten the results			
			$line = preg_replace('/\s\s+/', ',', $line);
			$line = str_replace('\\', '/', $line);
			$line = str_replace('//', '', $line);
			$line = preg_replace('/^./', '', $line);
			$line = str_replace("\t", '', $line);

			// load dropdown
			if (strpos($line, '/') !== false) {
				$srv = explode(',', $line, 2);
				$_address .= sprintf('<option value="%s" %s>%s</option>\n', $srv[0], '', $srv[0]);
			}
		}
	}
}
// manual entry
if (isset($_POST['manualentry']) && $_POST['manualentry'] == 1) {
	$_GET['cmd'] = $_SESSION['nas_action'];
	$_GET['id'] = $_SESSION['nas_mpid'];
}

// initiate db update if indicated after sourcecfg job completes
waitWorker(1, 'src-config');
if ($initiateDBUpd == true) {
	//workerLog('src-config(): Job: updmpddb');
	submitJob('updmpddb', '', '', '');
}

// SOURCE CONFIG FORM
if (!isset($_GET['cmd'])) {
	$tpl = "src-config.html";

	// display list of nas sources if any
	$mounts = cfgdb_read('cfg_source',$dbh);
	foreach ($mounts as $mp) {
		$icon = mountExists($mp['name']) ? "<i class='fas fa-check green sx'></i>" : "<i class='fas fa-times red sx'></i>";
		$_mounts .= "<p><a href=\"src-config.php?cmd=edit&id=" . $mp['id'] . "\" class='btn btn-large' style='width: 240px; background-color: #333;'> " . $icon . " " . $mp['name'] . " (" . $mp['address'] . ") </a></p>";
	}
	
	// messages
	if ($mounts === true) {
		$_mounts .= '<p class="btn btn-large" style="width: 240px; background-color: #333;">None configured</p><p></p>';
		$_remount_disable = 'disabled';
	}
	elseif ($mounts === false) {
		$_mounts .= '<p class="btn btn-large" style="width: 240px; background-color: #333;">Query failed</p>';
		$_remount_disable = '';
	}

	// r44a auto-updatedb on usb insert/remove
	$_select['usb_auto_updatedb1'] = "<input type=\"radio\" name=\"usb_auto_updatedb\" id=\"toggle_usb_auto_updatedb0\" value=\"1\" " . (($_SESSION['usb_auto_updatedb'] == '1') ? "checked=\"checked\"" : "") . ">\n";
	$_select['usb_auto_updatedb0'] = "<input type=\"radio\" name=\"usb_auto_updatedb\" id=\"toggle_usb_auto_updatedb1\" value=\"0\" " . (($_SESSION['usb_auto_updatedb'] == '0') ? "checked=\"checked\"" : "") . ">\n";

	// thumbcache status
	$_thmcache_status = $_SESSION['thmcache_status']; // r43h
}

// NAS CONFIG FORM
if (isset($_GET['cmd']) && !empty($_GET['cmd'])) {
	$tpl = 'nas-config.html';

	// edit 
	if (isset($_GET['id']) && !empty($_GET['id'])) {
		$_id = $_GET['id'];
		$mounts = cfgdb_read('cfg_source',$dbh);

		foreach ($mounts as $mp) {
			if ($mp['id'] == $_id) {
				$_protocol = "<option value=\"" . ($mp['type'] == 'cifs' ? "cifs\">SMB (Samba)</option>" : "nfs\">NFS</option>");
				$server = isset($_POST['nas_manualserver']) && !empty(trim($_POST['nas_manualserver'])) ? $_POST['nas_manualserver'] : $mp['address'] . '/' . $mp['remotedir'];
				$_address .= sprintf('<option value="%s" %s>%s</option>\n', $server, 'selected', $server);
				$_scan_btn_hide = $mp['type'] == 'nfs' ? 'hide' : '';
				$_userid_pwd_hide = $mp['type'] == 'nfs' ? 'hide' : '';
				$_username = $mp['username'];
				$_password = $mp['password'];
				$_name = $mp['name'];
				$_charset = $mp['charset'];
				$_rsize = $mp['rsize'];
				$_wsize = $mp['wsize'];
				$_options = $mp['options'];
				$_error = $mp['error'];
				if (empty($_error)) {
					$_hide_error = 'hide';
				}
				else {
					$_moode_log = "\n" . file_get_contents(MOODELOG);
				}
			}
		}

		$_action = 'edit';

		session_start();
		$_SESSION['nas_action'] = $_action;
		$_SESSION['nas_mpid'] = $_id;
		session_write_close();
	}
	// create
	elseif ($_GET['cmd'] == 'add') {
		$_hide_remove = 'hide';
		$_hide_error = 'hide';

		if (isset($_POST['nas_manualserver'])) {
			if ($_POST['mounttype'] == 'cifs' || empty($_POST['mounttype'])) {
				$_protocol = "<option value=\"cifs\" selected>SMB (Samba)</option>\n";
				$_protocol .= "<option value=\"nfs\">NFS</option>\n";
				$_scan_btn_hide = '';
				$_userid_pwd_hide = '';
				$_options = 'vers=1.0,ro,dir_mode=0777,file_mode=0777';
			}
			else {
				$_protocol = "<option value=\"cifs\">SMB (Samba)</option>\n";
				$_protocol .= "<option value=\"nfs\" selected>NFS</option>\n";
				$_scan_btn_hide = 'hide';
				$_userid_pwd_hide = 'hide';
				$_options = 'ro,nolock';
			}
		}
		else {
			$_protocol = "<option value=\"cifs\">SMB (Samba)</option>\n";
			$_protocol .= "<option value=\"nfs\">NFS</option>\n";
			$_options = 'vers=1.0,ro,dir_mode=0777,file_mode=0777';
		}
		$server = isset($_POST['nas_manualserver']) && !empty(trim($_POST['nas_manualserver'])) ? $_POST['nas_manualserver'] : ' '; // space for select		
		$_address .= sprintf('<option value="%s" %s>%s</option>\n', $server, 'selected', $server);
		$_rsize = '61440';
		$_wsize = '65536';

		$_action = 'add';

		session_start();
		$_SESSION['nas_action'] = $_action;
		$_SESSION['nas_mpid'] = '';
		session_write_close();
	}
}

$section = basename(__FILE__, '.php');
include('/var/local/www/header.php'); 
eval("echoTemplate(\"".getTemplate("templates/$tpl")."\");");
include('footer.php');
