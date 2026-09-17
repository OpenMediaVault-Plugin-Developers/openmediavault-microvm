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
    public function getName()
    {
        return "MicroVm";
    }

    public function initialize()
    {
        $this->registerMethod('getSettings');
        $this->registerMethod('setSettings');

        $this->registerMethod('enumerateBridges');

        $this->registerMethod('getVmList');
        $this->registerMethod('getVm');
        $this->registerMethod('getVmNameStateList');
        $this->registerMethod('getVmDetails');
        $this->registerMethod('getConsoleLog');
        $this->registerMethod('setVm');
        $this->registerMethod('doCommand');

        $this->registerMethod('getImageList');
        $this->registerMethod('enumerateImages');
        $this->registerMethod('getImageCatalog');
        $this->registerMethod('downloadImage');
        $this->registerMethod('downloadCatalogImage');
        $this->registerMethod('deleteImage');
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

    private function unitName($name)
    {
        return sprintf("omv-microvm@%s.service", $name);
    }

    // The string a VM's `imageref` field stores and matches against —
    // name+arch, plus a version suffix when the image record has one. This
    // is a natural key (also used as the image's directory name) rather
    // than the image's own internal confdb uuid, so a VM's raw config is
    // self-describing without a join against the image table, and stays
    // valid even if the image row is later deleted.
    private function imageRef($object)
    {
        $version = trim($object->get('version'));
        if ($version === '') {
            return sprintf("%s-%s", $object->get('name'), $object->get('arch'));
        }
        return sprintf("%s-%s-%s", $object->get('name'), $object->get('arch'), $version);
    }

    // Human-readable label for an image, e.g. "ubuntu-24.04 (x86_64,
    // fc1.15-5.10.245)" or "ubuntu-24.04 (x86_64)" when it has no version.
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
        $isNew = $object->isNew();
        if (TRUE === $isNew) {
            $db->assertIsUnique($object, "name");
        } else {
            // The frontend disables the Image field once a VM exists (a
            // booted VM ignores it anyway — see omv-microvm-run), but
            // enforce it here too against direct RPC/API use.
            $existing = $db->get("conf.service.microvm.vm", $object->get('uuid'));
            if ($existing->get('imageref') !== $object->get('imageref')) {
                throw new \OMV\Exception(gettext(
                    "The image can only be set when a VM is created. Delete and recreate the VM to use a different image."
                ));
            }
        }
        $db->set($object);
        // The VM's confdb record is read fresh by omv-microvm-run every time
        // the unit starts, so nothing needs to be rendered to disk here — an
        // applyChanges is only needed to (re)enable the systemd instance per
        // the autostart flag.
        $this->applyChanges($context);
        return $object->getAssoc();
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
            case 'stop':
                // Hard stop: terminates the supervised process (systemd
                // sends SIGTERM to the whole cgroup). Firecracker does
                // expose a host-triggered graceful option (the
                // SendCtrlAltDel action over its API socket), but this VM
                // doesn't use it — deliberately kept simple for now.
                $this->systemctlCommand(['stop', $unit], gettext("Failed to stop VM."));
                break;
            case 'restart':
                $this->systemctlCommand(['restart', $unit], gettext("Failed to restart VM."));
                break;
            case 'forcestop':
                $this->systemctlCommand(['kill', '--signal=SIGKILL', $unit],
                    gettext("Failed to force stop VM."));
                break;
            case 'delete':
                $this->systemctlQuiet(['stop', $unit]);
                $this->systemctlQuiet(['disable', $unit]);
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
        // Uniqueness is on (name, arch, version), not name alone — the same
        // base image (e.g. "ubuntu-24.04") legitimately exists once per
        // architecture, and again once per version, and VMs/omv-microvm-run
        // reference an image by this ref string, not by its confdb uuid, so
        // a shared name across arches/versions is fine.
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
        // A VM only needs the shared image files for its first boot —
        // omv-microvm-run copies both the kernel and rootfs into the VM's
        // own directory the first time it starts, and uses that private
        // copy on every start after that. So an image referenced by a VM
        // that has already booted is safe to delete; only a VM that hasn't
        // taken its own copy yet would be left unable to start.
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
}
