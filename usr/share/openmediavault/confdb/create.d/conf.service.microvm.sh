#!/bin/sh
#
# @license   http://www.gnu.org/licenses/gpl.html GPL Version 3
# @author    OpenMediaVault Plugin Developers <plugins@omv-extras.org>
# @copyright Copyright (c) 2026 openmediavault plugin developers
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

set -e

. /etc/default/openmediavault
. /usr/share/openmediavault/scripts/helper-functions

if ! omv_config_exists "/config/services/microvm"; then
    omv_config_add_node "/config/services" "microvm"
    omv_config_add_key "/config/services/microvm" "enable" "1"
    omv_config_add_key "/config/services/microvm" "sharedfolderref" ""
    omv_config_add_key "/config/services/microvm" "install_cterm" "1"
    omv_config_add_node "/config/services/microvm" "vms"
    omv_config_add_node "/config/services/microvm" "images"
    omv_config_add_node "/config/services/microvm" "networks"
    omv_config_add_node "/config/services/microvm" "disks"
    omv_config_add_node "/config/services/microvm" "jobs"
fi

# Add keys that may be missing on upgrade.
if ! omv_config_exists "/config/services/microvm/enable"; then
    omv_config_add_key "/config/services/microvm" "enable" "1"
fi
if ! omv_config_exists "/config/services/microvm/sharedfolderref"; then
    omv_config_add_key "/config/services/microvm" "sharedfolderref" ""
fi
if ! omv_config_exists "/config/services/microvm/install_cterm"; then
    omv_config_add_key "/config/services/microvm" "install_cterm" "1"
fi
if ! omv_config_exists "/config/services/microvm/vms"; then
    omv_config_add_node "/config/services/microvm" "vms"
fi
if ! omv_config_exists "/config/services/microvm/images"; then
    omv_config_add_node "/config/services/microvm" "images"
fi
if ! omv_config_exists "/config/services/microvm/networks"; then
    omv_config_add_node "/config/services/microvm" "networks"
fi
if ! omv_config_exists "/config/services/microvm/disks"; then
    omv_config_add_node "/config/services/microvm" "disks"
fi
if ! omv_config_exists "/config/services/microvm/jobs"; then
    omv_config_add_node "/config/services/microvm" "jobs"
fi

exit 0
