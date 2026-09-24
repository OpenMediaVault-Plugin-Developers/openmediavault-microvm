<?php
/**
 * @license   http://www.gnu.org/licenses/gpl.html GPL Version 3
 * @author    OpenMediaVault Plugin Developers <plugins@omv-extras.org>
 * @copyright Copyright (c) 2026 openmediavault plugin developers
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */

class OMVRpcServiceMicroVm extends \OMV\Rpc\ServiceAbstract
{
    // Jailed VMs each get their own uid/gid, allocated upwards from here —
    // high enough to stay clear of regular users, systemd's dynamic users
    // and the usual container subuid ranges. They need no passwd entries.
    const JAIL_UID_BASE = 1500000000;

    public function getName()
    {
        return "MicroVm";
    }

    public function initialize()
    {
        $this->registerMethod('getSettings');
        $this->registerMethod('setSettings');

        $this->registerMethod('enumerateBridges');

        $this->registerMethod('getNetworkList');
        $this->registerMethod('getNetwork');
        $this->registerMethod('setNetwork');
        $this->registerMethod('deleteNetwork');

        $this->registerMethod('getVmList');
        $this->registerMethod('getVm');
        $this->registerMethod('getVmNameStateList');
        $this->registerMethod('enumerateVmNames');
        $this->registerMethod('getVmDetails');
        $this->registerMethod('getConsoleLog');
        $this->registerMethod('setVm');
        $this->registerMethod('doCommand');
        $this->registerMethod('resizeDisk');

        $this->registerMethod('getDiskList');
        $this->registerMethod('getDisk');
        $this->registerMethod('setDisk');
        $this->registerMethod('deleteDisk');
        $this->registerMethod('resizeDataDisk');

        $this->registerMethod('getImageList');
        $this->registerMethod('enumerateImages');
        $this->registerMethod('getImageCatalog');
        $this->registerMethod('downloadImage');
        $this->registerMethod('downloadCatalogImage');
        $this->registerMethod('deleteImage');

        $this->registerMethod('enumerateSnapshots');
        $this->registerMethod('createSnapshot');
        $this->registerMethod('restoreSnapshot');
        $this->registerMethod('deleteSnapshot');
        $this->registerMethod('deleteAllSnapshots');

        $this->registerMethod('getBackupList');
        $this->registerMethod('doBackup');
        $this->registerMethod('restoreBackup');
        $this->registerMethod('deleteBackup');
        $this->registerMethod('syncBackupList');

        $this->registerMethod('getJobList');
        $this->registerMethod('getJob');
        $this->registerMethod('setJob');
        $this->registerMethod('deleteJob');
        $this->registerMethod('doJob');
    }

    private function getStoragePath($context)
    {
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.microvm");
        $sfref = $object->get("sharedfolderref");
        if (!is_uuid($sfref)) {
            throw new \OMV\Exception(
                gettext("Please set a shared folder for VM/image storage on the Settings tab.")
            );
        }
        $sfpath = \OMV\Rpc\Rpc::call("ShareMgmt", "getPath", ["uuid" => $sfref], $context);
        return rtrim($sfpath, '/');
    }

    private function vmsDir($context)
    {
        return sprintf("%s/vms", $this->getStoragePath($context));
    }

    private function imagesDir($context)
    {
        return sprintf("%s/images", $this->getStoragePath($context));
    }

    private function snapshotsDir($context, $vmName)
    {
        return sprintf("%s/%s/snapshots", $this->vmsDir($context), $vmName);
    }

    // Data disks on the VM storage shared folder live inside the VM's own
    // directory; ones placed on another shared folder get a per-VM
    // subdirectory there. Must match omv-microvm-list-disks.
    private function diskPath($context, $disk)
    {
        $sfref = $disk->get('sharedfolderref');
        if (is_uuid($sfref)) {
            $sfpath = \OMV\Rpc\Rpc::call("ShareMgmt", "getPath", ["uuid" => $sfref], $context);
            return sprintf("%s/microvm-disks/%s/%s.img", rtrim($sfpath, '/'),
                $disk->get('vmref'), $disk->get('name'));
        }
        return sprintf("%s/%s/disks/%s.img", $this->vmsDir($context),
            $disk->get('vmref'), $disk->get('name'));
    }

    private function vmDisks($vmName)
    {
        $db = \OMV\Config\Database::getInstance();
        return $db->getByFilter("conf.service.microvm.disk", [
            "operator" => "stringEquals",
            "arg0" => "vmref",
            "arg1" => $vmName
        ]);
    }

    private function unitName($name)
    {
        return sprintf("omv-microvm@%s.service", $name);
    }

    // Natural key ("name-arch[-version]") a VM's imageref matches against,
    // rather than the image row's own confdb uuid.
    private function imageRef($object)
    {
        $version = trim($object->get('version'));
        if ($version === '') {
            return sprintf("%s-%s", $object->get('name'), $object->get('arch'));
        }
        return sprintf("%s-%s-%s", $object->get('name'), $object->get('arch'), $version);
    }

    private function imageDesc($object)
    {
        $version = trim($object->get('version'));
        if ($version === '') {
            return sprintf("%s (%s)", $object->get('name'), $object->get('arch'));
        }
        return sprintf("%s (%s, %s)", $object->get('name'), $object->get('arch'), $version);
    }

    // Map the raw systemd ActiveState of a VM's unit to a UI-friendly state.
    private function getActiveState($name)
    {
        $cmd = new \OMV\System\Process('systemctl', ['show', '-p', 'ActiveState',
            '--value', $this->unitName($name)]);
        $cmd->setQuiet(true);
        $cmd->execute($output, $exitStatus);
        $raw = trim(implode('', $output));
        switch ($raw) {
            case 'active':
                return 'running';
            case 'activating':
                return 'starting';
            case 'deactivating':
                return 'stopping';
            case 'failed':
                return 'error';
            case 'inactive':
            default:
                return 'stopped';
        }
    }

    // Mirrors openmediavault-kvm's own getExecUrl(): the base URL of the
    // cterm web terminal, or "" if cterm isn't installed/configured.
    // cterm has two deployment modes (see its own settings page and
    // nginx-cterm.conf.j2): reverse-proxied through the OMV web server
    // itself on its own host/port with a path prefix, or direct access
    // on cterm's own listening port. Mirrors what cterm's own Cterm::get()
    // RPC computes for its "Open UI" button.
    private function getExecUrl($context, $db, $fqdn)
    {
        try {
            $settings = $db->get("conf.service.cterm");
            $webadmin = $db->get("conf.webadmin");
            $useSsl = boolval($webadmin->get("enablessl"));
            $protocol = $useSsl ? "https" : "http";
            if (boolval($settings->get("enablenginx"))) {
                $basepath = trim(strval($settings->get("basepath")), "/");
                $proxypath = ($basepath !== "") ? sprintf("/%s", $basepath) : "";
                $defaultPort = $useSsl ? 443 : 80;
                $port = $useSsl ? $webadmin->get("sslport") : $webadmin->get("port");
                $portSuffix = ((int)$port === $defaultPort) ? "" : sprintf(":%d", $port);
                return sprintf('%s://%s%s%s/terminal', $protocol, $fqdn, $portSuffix, $proxypath);
            }
            $port = $settings->get("port");
            $basepath = $settings->get("basepath");
            return sprintf('%s://%s:%d%s/terminal', $protocol, $fqdn, $port, $basepath);
        } catch (\Exception $e) {
            // cterm not installed.
            return "";
        }
    }

    // Builds the HMAC-authenticated cterm console link for a running VM,
    // or "" if cterm is unavailable/disabled/the VM isn't running. Same
    // token scheme as openmediavault-kvm's LXC "Terminal Link" column.
    private function getConsoleTermUrl($name, $state, $context)
    {
        $db = \OMV\Config\Database::getInstance();
        $dns = $db->get('conf.system.network.dns');
        $fqdn = $dns->get('hostname');
        $domainName = $dns->get('domainname');
        if (strlen($domainName) > 1) {
            $fqdn = sprintf('%s.%s', $fqdn, $domainName);
        }
        try {
            $cterm = $db->get("conf.service.cterm");
        } catch (\Exception $e) {
            return "";
        }
        if ($state !== 'running' || 0 === (int)$cterm->get("enable")) {
            return "";
        }
        $secret = trim(@file_get_contents('/etc/omv_cterm.secret'));
        if (empty($secret)) {
            return "";
        }
        $autouser = $cterm->get('autouser') ?: $context['username'];
        $ts = sprintf('%s', microtime(true));
        $hmac = hash_hmac('sha256', sprintf('%s:%s', $autouser, $ts), $secret);
        $execUrl = $this->getExecUrl($context, $db, $fqdn);
        if (empty($execUrl)) {
            return "";
        }
        return sprintf('%s/%s/firecracker?user=%s&hmac=%s&ts=%s',
            $execUrl, $name, $autouser, $hmac, $ts);
    }

    private function getVmObjectByName($name)
    {
        $db = \OMV\Config\Database::getInstance();
        $objects = $db->getByFilter("conf.service.microvm.vm", [
            "operator" => "stringEquals",
            "arg0" => "name",
            "arg1" => $name
        ]);
        if (empty($objects)) {
            throw new \OMV\Exception(sprintf(gettext("VM '%s' not found."), $name));
        }
        return $objects[0];
    }

    public function getSettings($params, $context)
    {
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.microvm");
        $object->remove("vms");
        $object->remove("images");
        $object->remove("disks");
        $assoc = $object->getAssoc();
        $assoc['firecracker_version'] = $this->getFirecrackerVersion();
        return $assoc;
    }

    private function getFirecrackerVersion()
    {
        // Called by full path, not "firecracker" bare — omv-engined's PATH
        // does not reliably include /usr/local/bin, where omv-install-fc
        // and the salt state both put the binary.
        $cmd = new \OMV\System\Process('/usr/local/bin/firecracker', ['--version']);
        $cmd->setQuiet(true);
        $cmd->execute($output, $exitStatus);
        if (0 !== $exitStatus) {
            return gettext("Not installed");
        }
        return $output[0] ?? gettext("Not installed");
    }

    public function setSettings($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, "rpc.microvm.setsettings");
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.microvm");
        $object->setAssoc($params);
        $db->set($object);
        $object->remove("vms");
        $object->remove("images");
        $object->remove("disks");
        return $object->getAssoc();
    }

    public function enumerateBridges($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $objects = [];
        foreach (glob('/sys/class/net/br*', GLOB_ONLYDIR) as $path) {
            $bridge = basename($path);
            // Skip Docker-managed bridges (named "br-" + 12 hex chars) — Docker
            // owns their firewall rules, so they must not be offered here.
            if (preg_match('/^br-[0-9a-f]{12}$/', $bridge)) {
                continue;
            }
            $objects[] = ['bridge' => $bridge];
        }
        return $objects;
    }

    public function getNetworkList($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, "rpc.common.getlist");
        $db = \OMV\Config\Database::getInstance();
        $objects = [];
        foreach ($db->getAssoc("conf.service.microvm.network") as $object) {
            $object['details'] = $this->networkDetails($object);
            $objects[] = $object;
        }
        return $this->applyFilter($objects, $params['start'], $params['limit'],
            $params['sortfield'], $params['sortdir']);
    }

    private function networkDetails($network)
    {
        if ('nat' === $network['type']) {
            $details = $network['subnet'];
            if ($network['dhcp']) {
                $details .= sprintf(' (%s)', gettext("DHCP"));
            }
            return $details;
        }
        return $network['bridge'];
    }

    public function getNetwork($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, "rpc.common.objectuuid");
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.microvm.network", $params['uuid']);
        return $object->getAssoc();
    }

    public function setNetwork($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, "rpc.microvm.setnetwork");
        if ('bridge' === $params['type'] && empty($params['bridge'])) {
            throw new \OMV\Exception(gettext("A bridge device must be selected for a host bridge network."));
        }
        if ('nat' === $params['type']) {
            if (empty($params['subnet'])) {
                throw new \OMV\Exception(gettext("A subnet is required for a private NAT network."));
            }
            if (!preg_match('#^(\d{1,3}\.){3}\d{1,3}/\d{1,2}$#', $params['subnet'])) {
                throw new \OMV\Exception(gettext("Subnet must be in CIDR notation, e.g. 172.30.0.0/24."));
            }
        }
        $db = \OMV\Config\Database::getInstance();
        $object = new \OMV\Config\ConfigObject("conf.service.microvm.network");
        $object->setAssoc($params);
        if (TRUE === $object->isNew()) {
            $db->assertIsUnique($object, "name");
        } else {
            // Enforce server-side too, against direct RPC/API use.
            $existing = $db->get("conf.service.microvm.network", $object->get('uuid'));
            if ($existing->get('name') !== $object->get('name')) {
                throw new \OMV\Exception(gettext(
                    "The name can only be set when a network is created. Delete and recreate the network to use a different name."
                ));
            }
        }
        $db->set($object);
        $this->syncDhcpServer($object);
        $this->applyChanges($context);
        return $object->getAssoc();
    }

    // The DHCP server is started by the first VM that starts on a network
    // (see omv-microvm-run); this only follows setting changes for a
    // network that is already up. VMs already running on it registered
    // their reservations when they started only if DHCP was on then.
    private function syncDhcpServer($network)
    {
        $name = $network->get('name');
        $unit = sprintf("omv-microvm-dhcp@%s.service", $name);
        if ('nat' !== $network->get('type') || !boolval($network->get('dhcp'))) {
            $this->systemctlQuiet(['stop', $unit]);
            return;
        }
        // Must match omv-microvm-ensure-nat-network.
        $bridge = sprintf("mvm-nat-%s", substr(md5($name), 0, 7));
        if (is_dir(sprintf("/sys/class/net/%s", $bridge))) {
            $this->systemctlQuiet(['restart', $unit]);
        }
    }

    public function deleteNetwork($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, "rpc.common.objectuuid");
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.microvm.network", $params['uuid']);
        $name = $object->get('name');
        foreach ($db->get("conf.service.microvm.vm") as $vm) {
            if ($vm->get('networkref') === $name) {
                throw new \OMV\Exception(sprintf(
                    gettext("Network '%s' is still used by VM '%s'. Change that VM's network first."),
                    $name, $vm->get('name')
                ));
            }
        }
        if ('nat' === $object->get('type')) {
            $cmd = new \OMV\System\Process('omv-microvm-teardown-nat-network', [$name]);
            $cmd->setQuiet(true);
            $cmd->execute();
        }
        $db->delete($object);
        $this->applyChanges($context);
        return $object->getAssoc();
    }

    public function getVmList($params, $context)
    {
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, "rpc.common.getlist");
        $db = \OMV\Config\Database::getInstance();
        $imageNames = [];
        foreach ($db->get("conf.service.microvm.image") as $image) {
            $imageNames[$this->imageRef($image)] = $this->imageDesc($image);
        }
        $objects = [];
        foreach ($db->get("conf.service.microvm.vm") as $object) {
            $assoc = $object->getAssoc();
            $assoc['state'] = $this->getActiveState($object->get('name'));
            $assoc['image_desc'] = $imageNames[$assoc['imageref']] ?? gettext("(unknown image)");
            $assoc['termurl'] = $this->getConsoleTermUrl($assoc['name'], $assoc['state'], $context);
            $assoc['snapshot_count'] = count($this->listSnapshots($context, $object));
            $rootfsPath = sprintf("%s/%s/rootfs.ext4", $this->vmsDir($context), $assoc['name']);
            $assoc['disk_size_mib'] = file_exists($rootfsPath)
                ? (int) ceil(filesize($rootfsPath) / 1048576) : null;
            $assoc['data_disk_count'] = count($this->vmDisks($assoc['name']));
            $objects[] = $assoc;
        }
        return $this->applyFilter($objects, $params['start'], $params['limit'],
            $params['sortfield'], $params['sortdir']);
    }

    public function getVm($params, $context)
    {
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, "rpc.common.objectuuid");
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.microvm.vm", $params['uuid']);
        return $object->getAssoc();
    }

    public function getVmNameStateList($params, $context)
    {
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, "rpc.common.getlist");
        $db = \OMV\Config\Database::getInstance();
        $objects = [];
        foreach ($db->get("conf.service.microvm.vm") as $object) {
            $objects[] = [
                'name' => $object->get('name'),
                'state' => $this->getActiveState($object->get('name')),
                'vcpus' => $object->get('vcpus'),
                'memory_mib' => $object->get('memory_mib')
            ];
        }
        return $this->applyFilter($objects, $params['start'], $params['limit'],
            $params['sortfield'], $params['sortdir']);
    }

    public function enumerateVmNames($params, $context)
    {
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        $db = \OMV\Config\Database::getInstance();
        $objects = [];
        foreach ($db->get("conf.service.microvm.vm") as $object) {
            $objects[] = [
                'uuid' => $object->get('uuid'),
                'name' => $object->get('name')
            ];
        }
        return $objects;
    }

    public function getVmDetails($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, "rpc.microvm.name");
        $object = $this->getVmObjectByName($params['name']);
        $name = $object->get('name');

        $cmd = new \OMV\System\Process('systemctl', ['status', '--no-pager',
            '--full', $this->unitName($name)]);
        $cmd->setQuiet(true);
        $cmd->execute($output, $exitStatus);
        $vminfo = implode(PHP_EOL, $output);
        $state = $this->getActiveState($name);

        return [
            'name' => $name,
            'state' => $state,
            'vminfo' => $vminfo,
            'consolelog' => $this->getConsoleLog(['name' => $name], $context),
            'termurl' => $this->getConsoleTermUrl($name, $state, $context)
        ];
    }

    public function getConsoleLog($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, "rpc.microvm.name");
        $logFile = sprintf("%s/%s/console.log", $this->vmsDir($context), $params['name']);
        if (!file_exists($logFile)) {
            return gettext("(no console output yet)");
        }
        $cmd = new \OMV\System\Process('tail', ['-n', '200', $logFile]);
        $cmd->setQuiet(true);
        $cmd->execute($output, $exitStatus);
        return implode(PHP_EOL, $output);
    }

    public function setVm($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, "rpc.microvm.setvm");
        $db = \OMV\Config\Database::getInstance();
        $object = new \OMV\Config\ConfigObject("conf.service.microvm.vm");
        $object->setAssoc($params);
        $networkExists = FALSE;
        foreach ($db->get("conf.service.microvm.network") as $network) {
            if ($network->get('name') === $object->get('networkref')) {
                $networkExists = TRUE;
                break;
            }
        }
        if (FALSE === $networkExists) {
            throw new \OMV\Exception(sprintf(
                gettext("Network '%s' does not exist."), $object->get('networkref')
            ));
        }
        $isNew = $object->isNew();
        if (TRUE === $isNew) {
            $db->assertIsUnique($object, "name");
            $object->set('jail_uid', 0);
        } else {
            $existing = $db->get("conf.service.microvm.vm", $object->get('uuid'));
            // Allocated once, never taken from the client.
            $object->set('jail_uid', $existing->get('jail_uid'));
            // Optional for API callers that predate these settings.
            foreach (['jailer', 'shutdown_timeout'] as $key) {
                if (!array_key_exists($key, $params)) {
                    $object->set($key, $existing->get($key));
                }
            }
            if (boolval($existing->get('jailer')) !== boolval($object->get('jailer'))) {
                $state = $this->getActiveState($existing->get('name'));
                if (!in_array($state, ['stopped', 'error'], true)) {
                    throw new \OMV\Exception(sprintf(
                        gettext("VM '%s' is %s; it must be stopped before the jailer setting can be changed."),
                        $existing->get('name'), $state));
                }
            }
            // Enforce server-side too, against direct RPC/API use.
            if ($existing->get('imageref') !== $object->get('imageref')) {
                throw new \OMV\Exception(gettext(
                    "The image can only be set when a VM is created. Delete and recreate the VM to use a different image."
                ));
            }
            if ($existing->get('name') !== $object->get('name')) {
                throw new \OMV\Exception(gettext(
                    "The name can only be set when a VM is created. Delete and recreate the VM to use a different name."
                ));
            }
        }
        if (boolval($object->get('jailer')) && 0 === (int) $object->get('jail_uid')) {
            $object->set('jail_uid', $this->allocateJailUid());
        }
        $db->set($object);
        // The VM's confdb record is read fresh by omv-microvm-run every time
        // the unit starts, so nothing needs to be rendered to disk here — an
        // applyChanges is only needed to (re)enable the systemd instance per
        // the autostart flag.
        $this->applyChanges($context);
        return $object->getAssoc();
    }

    private function allocateJailUid()
    {
        $db = \OMV\Config\Database::getInstance();
        $max = self::JAIL_UID_BASE - 1;
        foreach ($db->get("conf.service.microvm.vm") as $vm) {
            $max = max($max, (int) $vm->get('jail_uid'));
        }
        return $max + 1;
    }

    public function doCommand($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, "rpc.microvm.docommand");
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.microvm.vm", $params['uuid']);
        $name = $object->get('name');
        $unit = $this->unitName($name);

        switch ($params['command']) {
            case 'start':
                $this->systemctlCommand(['start', $unit], gettext("Failed to start VM."));
                break;
            // Not waited for: the unit's ExecStop (omv-microvm-shutdown)
            // gives the guest up to its shutdown timeout to go down, which
            // can outlast the web UI's request timeout. The VM list shows
            // 'stopping' meanwhile.
            case 'stop':
                $this->systemctlCommand(['stop', '--no-block', $unit], gettext("Failed to stop VM."));
                break;
            case 'restart':
                $this->systemctlCommand(['restart', '--no-block', $unit], gettext("Failed to restart VM."));
                break;
            case 'forcestop':
                $this->systemctlCommand(['kill', '--signal=SIGKILL', $unit],
                    gettext("Failed to force stop VM."));
                break;
            case 'delete':
                // No point shutting down a guest that's being deleted, and
                // this has to finish within the request.
                $this->systemctlQuiet(['kill', '--signal=SIGKILL', $unit]);
                $this->systemctlQuiet(['stop', $unit]);
                $this->systemctlQuiet(['disable', $unit]);
                // Its DHCP reservation, if it's on a DHCP network (see
                // omv-microvm-run).
                foreach (glob(sprintf('/run/openmediavault-microvm-dhcp/*/hosts/%s', $name)) as $f) {
                    @unlink($f);
                }
                // Data disks go with the VM, wherever they're stored.
                foreach ($this->vmDisks($name) as $disk) {
                    $diskPath = $this->diskPath($context, $disk);
                    if (file_exists($diskPath)) {
                        unlink($diskPath);
                    }
                    $db->delete($disk);
                }
                $vmDir = sprintf("%s/%s", $this->vmsDir($context), $name);
                if (is_dir($vmDir)) {
                    $rmCmd = new \OMV\System\Process('rm', ['-rf', $vmDir]);
                    $rmCmd->execute();
                }
                $db->delete($object);
                $this->applyChanges($context);
                break;
            case 'autostartenable':
                $object->set('autostart', true);
                $db->set($object);
                $this->systemctlQuiet(['enable', $unit]);
                $this->applyChanges($context);
                break;
            case 'autostartdisable':
                $object->set('autostart', false);
                $db->set($object);
                $this->systemctlQuiet(['disable', $unit]);
                $this->applyChanges($context);
                break;
        }
        return $object->getAssoc();
    }

    public function resizeDisk($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, "rpc.microvm.resizedisk");
        $db = \OMV\Config\Database::getInstance();
        $vm = $db->get("conf.service.microvm.vm", $params['vmuuid']);
        $name = $vm->get('name');
        $state = $this->getActiveState($name);
        if ($state !== 'stopped') {
            throw new \OMV\Exception(sprintf(
                gettext("VM '%s' is %s; it must be stopped before its disk can be resized."), $name, $state));
        }
        $rootfsPath = sprintf("%s/%s/rootfs.ext4", $this->vmsDir($context), $name);
        if (!file_exists($rootfsPath)) {
            throw new \OMV\Exception(sprintf(
                gettext("VM '%s' has never been started; there is no disk to resize yet."), $name));
        }
        // size_mib arrives as a numeric string, not an integer: it's rendered
        // through the workbench's Nunjucks-based param templating (see
        // omv-services-microvm-vm-datatable-page.yaml's "Resize disk"
        // taskDialog), which always produces a string — same reason
        // rpc.backup.doPurge's "keep" is a string param, not an integer.
        $sizeMib = (int) $params['size_mib'];
        if ($sizeMib < 128 || $sizeMib > 1048576) {
            throw new \OMV\Exception(gettext("New size must be between 128 and 1048576 MiB."));
        }
        $currentMib = (int) ceil(filesize($rootfsPath) / 1048576);
        if ($sizeMib <= $currentMib) {
            throw new \OMV\Exception(sprintf(
                gettext("New size (%d MiB) must be larger than the current disk size (%d MiB). Shrinking is not supported."),
                $sizeMib, $currentMib));
        }

        return $this->execBgProc(function ($bgStatusFilename, $bgOutputFilename)
            use ($name, $sizeMib) {
                $cmd = new \OMV\System\Process('omv-microvm-resize-disk', [$name, $sizeMib]);
                $cmd->setRedirect2to1();
                $cmdLine = $cmd->getCommandLine();
                if (0 !== $this->exec($cmdLine, $output, $bgOutputFilename)) {
                    throw new \OMV\ExecException($cmdLine, $output);
                }
                return $output;
            }
        );
    }

    public function getDiskList($params, $context)
    {
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, "rpc.common.getlist");
        $db = \OMV\Config\Database::getInstance();
        $objects = [];
        foreach ($db->get("conf.service.microvm.disk") as $object) {
            $assoc = $object->getAssoc();
            $path = $this->diskPath($context, $object);
            $assoc['path'] = $path;
            // Actual file size rather than the configured one, which only
            // records the size it was created or last resized to.
            $assoc['disk_size_mib'] = file_exists($path)
                ? (int) ceil(filesize($path) / 1048576) : null;
            $assoc['state'] = $this->getActiveState($object->get('vmref'));
            $objects[] = $assoc;
        }
        return $this->applyFilter($objects, $params['start'], $params['limit'],
            $params['sortfield'], $params['sortdir']);
    }

    public function getDisk($params, $context)
    {
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, "rpc.common.objectuuid");
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.microvm.disk", $params['uuid']);
        return $object->getAssoc();
    }

    public function setDisk($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, "rpc.microvm.setdisk");
        $db = \OMV\Config\Database::getInstance();
        $object = new \OMV\Config\ConfigObject("conf.service.microvm.disk");
        $object->setAssoc($params);
        if (FALSE === $object->isNew()) {
            // Only the attach options can change on an existing disk; its
            // size changes through resizeDataDisk.
            $existing = $db->get("conf.service.microvm.disk", $object->get('uuid'));
            foreach (['vmref', 'name', 'sharedfolderref', 'fstype'] as $key) {
                if ($existing->get($key) !== $object->get($key)) {
                    throw new \OMV\Exception(gettext(
                        "The VM, name, storage location and filesystem can only be set when a disk is created."
                    ));
                }
            }
            $object->set('size_mib', $existing->get('size_mib'));
            $db->set($object);
            return $object->getAssoc();
        }

        // Also the drive id Firecracker attaches it under, next to the
        // root drive's.
        if ('rootfs' === $object->get('name')) {
            throw new \OMV\Exception(gettext("'rootfs' is reserved and can't be used as a disk name."));
        }
        $this->getVmObjectByName($object->get('vmref'));
        $db->assertIsUniqueByFilter($object, [
            "operator" => "and",
            "arg0" => ["operator" => "stringEquals", "arg0" => "vmref", "arg1" => $object->get('vmref')],
            "arg1" => ["operator" => "stringEquals", "arg0" => "name", "arg1" => $object->get('name')]
        ], sprintf(gettext("VM '%s' already has a disk named '%s'."),
            $object->get('vmref'), $object->get('name')));

        $path = $this->diskPath($context, $object);
        if (file_exists($path)) {
            // Reattach a disk image left behind by an earlier "keep file"
            // delete, as-is.
            $object->set('size_mib', (int) ceil(filesize($path) / 1048576));
        } else {
            $this->createDiskImage($path, $object->get('size_mib'),
                $object->get('fstype'), $object->get('name'));
        }
        $db->set($object);
        return $object->getAssoc();
    }

    // Sparse, so creation is quick and only written blocks take up space.
    private function createDiskImage($path, $sizeMib, $fstype, $label)
    {
        $dir = dirname($path);
        if (!is_dir($dir) && !mkdir($dir, 0755, true)) {
            throw new \OMV\Exception(sprintf(gettext("Failed to create directory '%s'."), $dir));
        }
        $cmd = new \OMV\System\Process('truncate', ['-s', sprintf("%dM", $sizeMib), $path]);
        $cmd->execute();
        if ('ext4' !== $fstype) {
            return;
        }
        $cmd = new \OMV\System\Process('mkfs.ext4', ['-q', '-F', '-L', $label, $path]);
        $cmd->setRedirect2to1();
        $cmd->setQuiet(true);
        $cmd->execute($output, $exitStatus);
        if (0 !== $exitStatus) {
            @unlink($path);
            throw new \OMV\Exception("%s\n%s", gettext("Failed to create filesystem."),
                implode(PHP_EOL, $output));
        }
    }

    public function deleteDisk($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, "rpc.microvm.deletedisk");
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.microvm.disk", $params['uuid']);
        $vmName = $object->get('vmref');
        $state = $this->getActiveState($vmName);
        if (!in_array($state, ['stopped', 'error'], true)) {
            throw new \OMV\Exception(sprintf(
                gettext("VM '%s' is %s; it must be stopped before a disk can be removed."), $vmName, $state));
        }
        // Boolean or "true"/"false": the delete dialog's param goes through
        // the same string-only workbench templating as resizeDisk's size_mib.
        if (TRUE === filter_var($params['deletefile'], FILTER_VALIDATE_BOOLEAN)) {
            $path = $this->diskPath($context, $object);
            if (file_exists($path)) {
                unlink($path);
            }
        }
        $db->delete($object);
        return $object->getAssoc();
    }

    public function resizeDataDisk($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, "rpc.microvm.resizedatadisk");
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.microvm.disk", $params['uuid']);
        $vmName = $object->get('vmref');
        $diskName = $object->get('name');
        $state = $this->getActiveState($vmName);
        if (!in_array($state, ['stopped', 'error'], true)) {
            throw new \OMV\Exception(sprintf(
                gettext("VM '%s' is %s; it must be stopped before its disks can be resized."), $vmName, $state));
        }
        $path = $this->diskPath($context, $object);
        if (!file_exists($path)) {
            throw new \OMV\Exception(sprintf(gettext("Disk image '%s' is missing."), $path));
        }
        // String for the same reason as resizeDisk's size_mib.
        $sizeMib = (int) $params['size_mib'];
        if ($sizeMib < 1 || $sizeMib > 16777216) {
            throw new \OMV\Exception(gettext("New size must be between 1 and 16777216 MiB."));
        }
        $currentMib = (int) ceil(filesize($path) / 1048576);
        if ($sizeMib <= $currentMib) {
            throw new \OMV\Exception(sprintf(
                gettext("New size (%d MiB) must be larger than the current disk size (%d MiB). Shrinking is not supported."),
                $sizeMib, $currentMib));
        }

        return $this->execBgProc(function ($bgStatusFilename, $bgOutputFilename)
            use ($vmName, $diskName, $sizeMib, $object, $db) {
                $cmd = new \OMV\System\Process('omv-microvm-resize-disk', [$vmName, $sizeMib, $diskName]);
                $cmd->setRedirect2to1();
                $cmdLine = $cmd->getCommandLine();
                if (0 !== $this->exec($cmdLine, $output, $bgOutputFilename)) {
                    throw new \OMV\ExecException($cmdLine, $output);
                }
                $object->set('size_mib', $sizeMib);
                $db->set($object);
                return $output;
            }
        );
    }

    private function systemctlCommand($args, $errorMsg)
    {
        $cmd = new \OMV\System\Process('systemctl', $args);
        $cmd->setQuiet(true);
        $cmd->execute($output, $exitStatus);
        if (0 !== $exitStatus) {
            throw new \OMV\Exception("%s\n%s", $errorMsg, implode(PHP_EOL, $output));
        }
    }

    private function systemctlQuiet($args)
    {
        $cmd = new \OMV\System\Process('systemctl', $args);
        $cmd->setQuiet(true);
        $cmd->execute($output, $exitStatus);
    }

    private function applyChanges($context)
    {
        \OMV\Rpc\Rpc::call('Config', 'applyChanges', [
            'modules' => ['microvm'],
            'force' => TRUE
        ], $context);
    }

    public function getImageList($params, $context)
    {
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, "rpc.common.getlist");
        $db = \OMV\Config\Database::getInstance();
        $objects = [];
        foreach ($db->get("conf.service.microvm.image") as $object) {
            $objects[] = $object->getAssoc();
        }
        return $this->applyFilter($objects, $params['start'], $params['limit'],
            $params['sortfield'], $params['sortdir']);
    }

    public function enumerateImages($params, $context)
    {
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        $db = \OMV\Config\Database::getInstance();
        $objects = [];
        foreach ($db->get("conf.service.microvm.image") as $object) {
            $objects[] = [
                'ref' => $this->imageRef($object),
                'desc' => $this->imageDesc($object)
            ];
        }
        return $objects;
    }

    // Returns the shipped catalog with a stable 'id' (its array index) added
    // to each entry, so the frontend can reference an entry by a single
    // scalar value in a select field.
    public function getImageCatalog($params, $context)
    {
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        $catalogFile = "/usr/share/openmediavault-microvm/image-catalog.json";
        if (!file_exists($catalogFile)) {
            return [];
        }
        $catalog = json_decode(file_get_contents($catalogFile), true);
        foreach ($catalog as $index => &$entry) {
            $entry['id'] = $index;
        }
        return $catalog;
    }

    public function downloadImage($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, "rpc.microvm.downloadimage");
        return $this->startImageDownload($params['name'], $params['arch'],
            $params['version'] ?? '', $params['kernel_url'], $params['rootfs_url'], $context);
    }

    public function downloadCatalogImage($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, "rpc.microvm.downloadcatalogimage");
        // The frontend select field's value may arrive as either a JSON
        // integer or a numeric string, depending on how the workbench
        // template engine resolved "{{ catalog_id | int }}" (it does not
        // reliably preserve type for a falsy value like 0).
        $catalogId = (int) $params['catalog_id'];
        $catalog = $this->getImageCatalog([], $context);
        if (!isset($catalog[$catalogId])) {
            throw new \OMV\Exception(gettext("Catalog entry not found."));
        }
        $entry = $catalog[$catalogId];
        return $this->startImageDownload($entry['name'], $entry['arch'], $entry['version'] ?? '',
            $entry['kernel_url'], $entry['rootfs_url'], $context);
    }

    private function startImageDownload($name, $arch, $version, $kernelUrl, $rootfsUrl, $context)
    {
        $db = \OMV\Config\Database::getInstance();
        $object = new \OMV\Config\ConfigObject("conf.service.microvm.image");
        $object->set('name', $name);
        $object->set('arch', $arch);
        $object->set('version', $version);
        $ref = $this->imageRef($object);
        // Unique on (name, arch, version), not name alone.
        $db->assertIsUniqueByFilter($object, [
            "operator" => "and",
            "arg0" => ["operator" => "stringEquals", "arg0" => "name", "arg1" => $name],
            "arg1" => [
                "operator" => "and",
                "arg0" => ["operator" => "stringEquals", "arg0" => "arch", "arg1" => $arch],
                "arg1" => ["operator" => "stringEquals", "arg0" => "version", "arg1" => $version]
            ]
        ], sprintf(gettext("An image '%s' already exists."), $ref));
        $destDir = sprintf("%s/%s", $this->imagesDir($context), $ref);

        return $this->execBgProc(function ($bgStatusFilename, $bgOutputFilename)
            use ($arch, $version, $kernelUrl, $rootfsUrl, $destDir, $object, $db) {
                $cmdArgs = [$destDir, $kernelUrl, $rootfsUrl];
                $cmd = new \OMV\System\Process('omv-microvm-image-download', $cmdArgs);
                $cmd->setRedirect2to1();
                $cmdLine = $cmd->getCommandLine();
                if (0 !== $this->exec($cmdLine, $output, $bgOutputFilename)) {
                    throw new \OMV\ExecException($cmdLine, $output);
                }
                $kernelPath = sprintf("%s/vmlinux", $destDir);
                $rootfsPath = sprintf("%s/rootfs.ext4", $destDir);
                $size = (@filesize($kernelPath) ?: 0) + (@filesize($rootfsPath) ?: 0);
                $object->set('arch', $arch);
                $object->set('version', $version);
                $object->set('kernel_path', $kernelPath);
                $object->set('rootfs_path', $rootfsPath);
                $object->set('source_url', $kernelUrl);
                $object->set('size_bytes', $size);
                $object->set('imported', date('c'));
                $db->set($object);
                return $output;
            }
        );
    }

    public function deleteImage($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, "rpc.common.objectuuid");
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.microvm.image", $params['uuid']);
        $ref = $this->imageRef($object);
        // Safe to delete once a referencing VM has its own kernel/rootfs
        // copy (see omv-microvm-run) — only a never-booted VM still needs it.
        foreach ($db->get("conf.service.microvm.vm") as $vm) {
            if ($vm->get('imageref') !== $ref) {
                continue;
            }
            $vmDir = sprintf("%s/%s", $this->vmsDir($context), $vm->get('name'));
            $hasOwnCopy = file_exists(sprintf("%s/vmlinux", $vmDir))
                && file_exists(sprintf("%s/rootfs.ext4", $vmDir));
            if (!$hasOwnCopy) {
                throw new \OMV\Exception(sprintf(
                    gettext("Image '%s' is still needed by VM '%s', which hasn't booted yet and would fail to start without it."),
                    $ref, $vm->get('name')
                ));
            }
        }
        $imageDir = sprintf("%s/%s", $this->imagesDir($context), $ref);
        if (is_dir($imageDir)) {
            $rmCmd = new \OMV\System\Process('rm', ['-rf', $imageDir]);
            $rmCmd->execute();
        }
        // No applyChanges: like the image download path, nothing in salt
        // consumes the image library, so there's no config to re-apply.
        $db->delete($object);
    }

    // Snapshots aren't tracked in confdb (like openmediavault-kvm's own
    // snapshot feature) — each is just VM_DIR/snapshots/<id>/ with a
    // meta.json sidecar, so deleting a VM's directory cleans them up too.
    private function listSnapshots($context, $vm)
    {
        $dir = $this->snapshotsDir($context, $vm->get('name'));
        $objects = [];
        foreach (glob(sprintf("%s/*/meta.json", $dir)) as $metaFile) {
            $meta = json_decode(file_get_contents($metaFile), true);
            if (!is_array($meta)) {
                continue;
            }
            $meta['id'] = basename(dirname($metaFile));
            $objects[] = $meta;
        }
        return $objects;
    }

    public function enumerateSnapshots($params, $context)
    {
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, "rpc.microvm.enumeratesnapshots");
        $db = \OMV\Config\Database::getInstance();
        $vm = $db->get("conf.service.microvm.vm", $params['vmuuid']);
        $objects = [];
        foreach ($this->listSnapshots($context, $vm) as $snap) {
            $objects[] = [
                'snapshotid' => $snap['id'],
                'desc' => sprintf("%s (%s)", $snap['name'] ?? '', $snap['created'] ?? '')
            ];
        }
        return $objects;
    }

    public function createSnapshot($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, "rpc.microvm.createsnapshot");
        $db = \OMV\Config\Database::getInstance();
        $vm = $db->get("conf.service.microvm.vm", $params['vmuuid']);
        $name = $vm->get('name');
        $state = $this->getActiveState($name);
        if (!in_array($state, ['running', 'stopped'], true)) {
            throw new \OMV\Exception(sprintf(
                gettext("VM '%s' is %s; must be running or stopped to take a snapshot."), $name, $state));
        }
        // 'stopped' also covers a VM that has never been started — it gets
        // its own rootfs copy only on first boot (see omv-microvm-run), so
        // there's nothing to snapshot yet.
        $rootfsPath = sprintf("%s/%s/rootfs.ext4", $this->vmsDir($context), $name);
        if (!file_exists($rootfsPath)) {
            throw new \OMV\Exception(sprintf(
                gettext("VM '%s' has never been started; there is nothing to snapshot yet."), $name));
        }
        $snapshotId = bin2hex(random_bytes(8));
        $snapshotDir = sprintf("%s/%s", $this->snapshotsDir($context, $name), $snapshotId);
        $snapshotName = $params['name'];
        $notes = $params['notes'] ?? '';

        return $this->execBgProc(function ($bgStatusFilename, $bgOutputFilename)
            use ($name, $snapshotDir, $snapshotName, $notes) {
                $cmd = new \OMV\System\Process('omv-microvm-snapshot-create', [$name, $snapshotDir]);
                $cmd->setRedirect2to1();
                $cmdLine = $cmd->getCommandLine();
                if (0 !== $this->exec($cmdLine, $output, $bgOutputFilename)) {
                    throw new \OMV\ExecException($cmdLine, $output);
                }
                $size = 0;
                foreach (glob(sprintf("%s/*", $snapshotDir)) as $f) {
                    $size += @filesize($f) ?: 0;
                }
                $meta = [
                    'name' => $snapshotName,
                    'notes' => $notes,
                    'created' => date('c'),
                    'size_bytes' => $size
                ];
                file_put_contents(sprintf("%s/meta.json", $snapshotDir), json_encode($meta));
                return $output;
            }
        );
    }

    public function restoreSnapshot($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, "rpc.microvm.snapshot");
        $db = \OMV\Config\Database::getInstance();
        $vm = $db->get("conf.service.microvm.vm", $params['vmuuid']);
        $name = $vm->get('name');
        $unit = $this->unitName($name);
        $snapshotDir = sprintf("%s/%s", $this->snapshotsDir($context, $name), $params['snapshotid']);
        if (!is_dir($snapshotDir)) {
            throw new \OMV\Exception(sprintf(gettext("Snapshot '%s' not found."), $params['snapshotid']));
        }

        return $this->execBgProc(function ($bgStatusFilename, $bgOutputFilename)
            use ($unit, $name, $snapshotDir) {
                $this->systemctlQuiet(['stop', $unit]);
                $cmd = new \OMV\System\Process('omv-microvm-snapshot-restore', [$name, $snapshotDir]);
                $cmd->setRedirect2to1();
                $cmdLine = $cmd->getCommandLine();
                if (0 !== $this->exec($cmdLine, $output, $bgOutputFilename)) {
                    throw new \OMV\ExecException($cmdLine, $output);
                }
                $this->systemctlCommand(['start', $unit], gettext("Failed to start VM after restore."));
                return $output;
            }
        );
    }

    public function deleteSnapshot($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, "rpc.microvm.snapshot");
        $db = \OMV\Config\Database::getInstance();
        $vm = $db->get("conf.service.microvm.vm", $params['vmuuid']);
        $snapshotDir = sprintf("%s/%s", $this->snapshotsDir($context, $vm->get('name')), $params['snapshotid']);
        if (is_dir($snapshotDir)) {
            $rmCmd = new \OMV\System\Process('rm', ['-rf', $snapshotDir]);
            $rmCmd->execute();
        }
    }

    public function deleteAllSnapshots($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, "rpc.microvm.enumeratesnapshots");
        $db = \OMV\Config\Database::getInstance();
        $vm = $db->get("conf.service.microvm.vm", $params['vmuuid']);
        $dir = $this->snapshotsDir($context, $vm->get('name'));
        if (is_dir($dir)) {
            $rmCmd = new \OMV\System\Process('rm', ['-rf', $dir]);
            $rmCmd->execute();
        }
    }

    // Backups are similar to snapshots (same underlying capture/restore
    // scripts) but write to an admin-chosen directory instead of the VM's
    // own fixed snapshots dir, so a single browsable list can span many
    // destinations. That needs an index outside any one VM's directory —
    // /etc/omv-microvm-backup.list, appended to by omv-microvm-backup
    // itself, one row per restore point: uuid,path,vmname,date,size.
    private function backupListFile()
    {
        return '/etc/omv-microvm-backup.list';
    }

    public function getBackupList($params, $context)
    {
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, "rpc.common.getlist");
        $objects = [];
        $listFile = $this->backupListFile();
        if (file_exists($listFile)) {
            $lines = file($listFile, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
            if ($lines !== false) {
                $rows = array_map('str_getcsv', $lines);
                $header = ['uuid', 'path', 'vmname', 'date', 'size'];
                foreach ($rows as $row) {
                    if (count($row) < count($header)) {
                        continue;
                    }
                    $object = array_combine($header, array_slice($row, 0, count($header)));
                    $backupDir = sprintf('%s/%s/%s', rtrim($object['path'], '/'),
                        $object['vmname'], $object['date']);
                    $meta = [];
                    $metaFile = sprintf('%s/meta.json', $backupDir);
                    if (file_exists($metaFile)) {
                        $decoded = json_decode(file_get_contents($metaFile), true);
                        if (is_array($decoded)) {
                            $meta = $decoded;
                        }
                    }
                    $object['name'] = $meta['name'] ?? '';
                    $object['notes'] = $meta['notes'] ?? '';
                    $object['warm'] = $meta['warm'] ?? false;
                    // Recompute size live from the current files rather than
                    // trusting the stored value, which can go stale (e.g.
                    // filesystem compression/sparseness settling after the
                    // write).
                    $size = 0;
                    $found = false;
                    foreach ((is_dir($backupDir) ? glob($backupDir . '/*') : []) as $f) {
                        if (is_file($f)) {
                            $size += @filesize($f) ?: 0;
                            $found = true;
                        }
                    }
                    if ($found) {
                        $object['size'] = (string)$size;
                    }
                    $objects[] = $object;
                }
            }
        }
        return $this->applyFilter($objects, $params['start'], $params['limit'],
            $params['sortfield'], $params['sortdir']);
    }

    public function doBackup($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, 'rpc.microvm.dobackup');
        $path = $params['path'];
        if (substr($path, 0, 1) !== '/') {
            $path = '/' . $path;
        }
        return $this->execBgProc(function ($bgStatusFilename, $bgOutputFilename)
            use ($params, $path) {
                $cmdArgs = ['-v', $params['vmname'], '-d', $path];
                if (!empty($params['keep'])) {
                    $cmdArgs[] = '-k';
                    $cmdArgs[] = (string)(int)$params['keep'];
                }
                if (!empty($params['name'])) {
                    $cmdArgs[] = '-n';
                    $cmdArgs[] = $params['name'];
                }
                if (!empty($params['notes'])) {
                    $cmdArgs[] = '-N';
                    $cmdArgs[] = $params['notes'];
                }
                $cmd = new \OMV\System\Process('/usr/sbin/omv-microvm-backup', $cmdArgs);
                $cmd->setRedirect2to1();
                $cmdLine = $cmd->getCommandLine();
                if (0 !== $this->exec($cmdLine, $output, $bgOutputFilename)) {
                    throw new \OMV\ExecException($cmdLine, $output);
                }
                return $output;
            }
        );
    }

    public function restoreBackup($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, 'rpc.microvm.restorebackup');
        $db = \OMV\Config\Database::getInstance();
        $vm = $db->get('conf.service.microvm.vm', $params['vmuuid']);
        $name = $vm->get('name');
        $unit = $this->unitName($name);
        $backupDir = sprintf('%s/%s/%s', rtrim($params['path'], '/'),
            $params['vmname'], $params['date']);
        if (!is_dir($backupDir)) {
            throw new \OMV\Exception(gettext("Backup not found."));
        }

        return $this->execBgProc(function ($bgStatusFilename, $bgOutputFilename)
            use ($unit, $name, $backupDir) {
                $this->systemctlQuiet(['stop', $unit]);
                $cmd = new \OMV\System\Process('/usr/sbin/omv-microvm-snapshot-restore', [$name, $backupDir]);
                $cmd->setRedirect2to1();
                $cmdLine = $cmd->getCommandLine();
                if (0 !== $this->exec($cmdLine, $output, $bgOutputFilename)) {
                    throw new \OMV\ExecException($cmdLine, $output);
                }
                $this->systemctlCommand(['start', $unit], gettext("Failed to start VM after restore."));
                return $output;
            }
        );
    }

    public function deleteBackup($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, 'rpc.microvm.backupentry');
        $backupDir = sprintf('%s/%s/%s', rtrim($params['path'], '/'),
            $params['vmname'], $params['date']);
        if (is_dir($backupDir) && strlen($backupDir) > 2) {
            $rmCmd = new \OMV\System\Process('rm', ['-rf', $backupDir]);
            $rmCmd->execute();
        }
        $listFile = $this->backupListFile();
        if (file_exists($listFile)) {
            $cmd = new \OMV\System\Process('sed', ['-i',
                sprintf('/^%s,/d', $params['uuid']), $listFile]);
            $cmd->execute();
        }
    }

    public function syncBackupList($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        return $this->execBgProc(function ($bgStatusFilename, $bgOutputFilename) {
            $cmd = new \OMV\System\Process('omv-microvm-sync-backups-list');
            $cmd->setRedirect2to1();
            $cmdLine = $cmd->getCommandLine();
            if (0 !== $this->exec($cmdLine, $output, $bgOutputFilename)) {
                throw new \OMV\ExecException($cmdLine, $output);
            }
            return $output;
        });
    }

    public function getJobList($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, "rpc.common.getlist");
        $db = \OMV\Config\Database::getInstance();
        $objects = $db->getAssoc("conf.service.microvm.job");
        return $this->applyFilter($objects, $params['start'], $params['limit'],
            $params['sortfield'], $params['sortdir']);
    }

    public function getJob($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, "rpc.common.objectuuid");
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.microvm.job", $params['uuid']);
        return $object->getAssoc();
    }

    public function setJob($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, "rpc.microvm.setjob");
        $db = \OMV\Config\Database::getInstance();
        $object = new \OMV\Config\ConfigObject("conf.service.microvm.job");
        if (substr($params['path'], 0, 1) !== '/') {
            $params['path'] = '/' . $params['path'];
        }
        $object->setAssoc($params);
        $db->set($object);
        $this->applyChanges($context);
        return $object->getAssoc();
    }

    public function deleteJob($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, "rpc.common.objectuuid");
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.microvm.job", $params['uuid']);
        $db->delete($object);
        $this->applyChanges($context);
        return $object->getAssoc();
    }

    public function doJob($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, "rpc.common.objectuuid");
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.microvm.job", $params['uuid']);
        return $this->execBgProc(function ($bgStatusFilename, $bgOutputFilename)
            use ($object) {
                $cmdArgs = ['-v', $object->get('vmname'), '-d', $object->get('path')];
                if ($object->get('keep') > 0) {
                    $cmdArgs[] = '-k';
                    $cmdArgs[] = (string)$object->get('keep');
                }
                $cmd = new \OMV\System\Process('/usr/sbin/omv-microvm-backup', $cmdArgs);
                $cmd->setRedirect2to1();
                $cmdLine = $cmd->getCommandLine();
                if (0 !== $this->exec($cmdLine, $output, $bgOutputFilename)) {
                    throw new \OMV\ExecException($cmdLine, $output);
                }
                return $output;
            }
        );
    }
}
