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

{% set config = salt['omv_conf.get']('conf.service.microvm') %}
{% set vms = salt['omv_conf.get']('conf.service.microvm.vm') %}
{% set fc_version = '1.17.0' %}

# Skipped mid-dpkg-transaction (e.g. this plugin's own postinst) — calling
# apt from inside a running transaction is unsafe; a later salt run picks
# it up.
{% if config.install_cterm and not salt['environ.get']('DPKG_MAINTSCRIPT_PACKAGE', '') %}
microvm_install_cterm:
  pkg.installed:
    - pkgs:
      - openmediavault-cterm: '>= 8'
{% endif %}

# Firecracker has no Debian package — omv-install-fc fetches the pinned
# static binary release from GitHub the first time, or whenever the
# installed version differs. It is idempotent, so this just re-runs it.
install_firecracker_binary:
  cmd.run:
    - name: omv-install-fc {{ fc_version }}
    - unless: /usr/local/bin/firecracker --version 2>/dev/null | grep -q "v{{ fc_version }}"

configure_microvm_template_unit:
  file.managed:
    - name: /etc/systemd/system/omv-microvm@.service
    - source:
      - salt://{{ tpldir }}/files/omv-microvm.service.j2
    - template: jinja
    - user: root
    - group: root
    - mode: '0644'

microvm_systemd_reload:
  module.run:
    - name: service.systemctl_reload
    - onchanges:
      - file: configure_microvm_template_unit

configure_microvm_logrotate:
  file.managed:
    - name: /etc/logrotate.d/openmediavault-microvm
    - contents: |
        /var/log/openmediavault-microvm.log {
          monthly
          missingok
          rotate 12
          compress
          notifempty
        }
    - user: root
    - group: root
    - mode: '0644'

{% for vm in vms %}
{% set unit = "omv-microvm@" ~ vm.name ~ ".service" %}
{% if vm.enable and vm.autostart %}
microvm_autostart_{{ vm.name }}:
  service.enabled:
    - name: {{ unit }}
    - require:
      - file: configure_microvm_template_unit
{% else %}
microvm_autostart_{{ vm.name }}:
  service.disabled:
    - name: {{ unit }}
    - require:
      - file: configure_microvm_template_unit
{% endif %}
{% endfor %}
