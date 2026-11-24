"""Host firewall (ufw): deny incoming traffic except SSH, the game servers and the website.

Docker publishes container ports with its own iptables rules, which ufw does not
filter. Setup only publishes the game ports and (with a domain) 80/443 publicly;
the database and the local website port are bound to 127.0.0.1. The firewall
therefore protects everything else on the host, such as services started later.
"""

import re

from configuration import ask_yes_no
from operations import run
from sshd import sshd

RULE_COMMENT = 'opencj-setup'


def collect_firewall():
    print('A firewall blocks all incoming connections except SSH, the game servers and the website.', flush=True)
    return {'enabled': ask_yes_no('Configure the host firewall (ufw)?', True)}


def ssh_ports():
    """Ports the running SSH server listens on, read from its effective configuration."""
    effective = sshd('-T')
    ports = sorted({int(line.split()[1]) for line in effective.splitlines() if re.fullmatch(r'port \d+', line)})
    if not ports:
        raise RuntimeError('Could not determine the SSH port; firewall left unchanged')
    return ports


def wanted_rules(plan, installations, extra_ssh_ports=()):
    """(port, protocol, action) for every service that must stay reachable.

    extra_ssh_ports opens an SSH port before SSH itself starts listening there,
    during a port move (ssh_hardening.move_port).
    """
    rules = [(port, 'tcp', 'limit') for port in {*ssh_ports(), *extra_ssh_ports}]
    for settings in installations:
        if settings.get('bind_ip', '0.0.0.0') != '127.0.0.1':
            rules.append((settings['port'], 'udp', 'allow'))
            rules.append((settings['port'], 'tcp', 'allow'))
        if settings.get('website', {}).get('domain'):
            rules.append((80, 'tcp', 'allow'))
            rules.append((443, 'tcp', 'allow'))
    return sorted(set(rules))


def remove_stale_rules(wanted_specs):
    """Delete setup's own rules (marked by comment) that are no longer wanted, such as an old game port.

    Rules are deleted highest number first, so the remaining numbers stay valid.
    """
    status = run(['ufw', 'status', 'numbered'])
    stale_numbers = []
    for line in status.splitlines():
        match = re.match(r'\[\s*(\d+)\]\s+(\S+)', line)
        if match and '# ' + RULE_COMMENT in line and match.group(2) not in wanted_specs:
            stale_numbers.append(int(match.group(1)))
    for number in sorted(stale_numbers, reverse=True):
        run(['ufw', '--force', 'delete', str(number)])


def configure_firewall(plan, installations, *, extra_ssh_ports=()):
    """Apply the rules for this host plan; SSH is allowed before the firewall is switched on.

    New rules are added before stale ones are removed, so SSH stays reachable throughout.
    """
    if not plan.get('firewall', {}).get('enabled'):
        return
    run(['apt-get', 'install', '-y', 'ufw'], timeout=600)
    rules = wanted_rules(plan, installations, extra_ssh_ports)
    run(['ufw', 'default', 'deny', 'incoming'])
    run(['ufw', 'default', 'allow', 'outgoing'])
    for port, protocol, action in rules:
        run(['ufw', action, f'{port}/{protocol}', 'comment', RULE_COMMENT])
    remove_stale_rules({f'{port}/{protocol}' for port, protocol, action in rules})
    run(['ufw', '--force', 'enable'])
    print('Firewall active. Open: ' + ', '.join(f'{port}/{protocol}' for port, protocol, action in rules))
