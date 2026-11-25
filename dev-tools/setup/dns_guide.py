"""DNS names for the website and game servers: which records to create, and whether they point here.

The public addresses come from this machine's own network interfaces; no outside
service is asked. A machine behind NAT (no public address on an interface) asks the
operator for its public IPv4 address once and keeps it in the host plan.
"""

import ipaddress
import json
import socket
import subprocess
import sys

from configuration import ask
from operations import run

# Interfaces that Docker creates; their addresses are never reachable from outside.
CONTAINER_INTERFACE_PREFIXES = ('docker', 'br-', 'veth')


def public_addresses(plan=None):
    """{'A': [...], 'AAAA': [...]}: global addresses on this machine's interfaces."""
    found = {'A': [], 'AAAA': []}
    for interface in json.loads(run(['ip', '-j', 'address', 'show', 'scope', 'global'])):
        if interface.get('ifname', '').startswith(CONTAINER_INTERFACE_PREFIXES):
            continue
        for entry in interface.get('addr_info', []):
            # `ip` lists interfaces without a matching address with empty entries.
            # Temporary (privacy) IPv6 addresses change daily; DNS must use the stable one.
            if 'local' not in entry or entry.get('temporary') or entry.get('deprecated'):
                continue
            address = ipaddress.ip_address(entry['local'])
            if address.is_global:
                found['A' if address.version == 4 else 'AAAA'].append(str(address))
    if not found['A'] and plan and plan.get('public_ipv4'):
        found['A'] = [plan['public_ipv4']]
    return found


def validate_public_ipv4(text):
    address = ipaddress.IPv4Address(text)
    if not address.is_global:
        raise ValueError('use the public IPv4 address (not 10.x, 172.16-31.x, 192.168.x)')
    return str(address)


def ensure_public_ipv4(plan):
    """Behind NAT, the operator supplies the public address (and forwards the ports to this machine)."""
    if public_addresses(plan)['A']:
        return
    print('This machine has no public IPv4 address on its network interfaces; it is probably behind a'
          ' router (NAT). Forward the game ports, 80 and 443 to it, and enter the public address'
          ' (your router or hosting panel shows it).', flush=True)
    plan['public_ipv4'] = ask('Public IPv4 address of this machine', parse=validate_public_ipv4)


def wanted_names(plan):
    """(name, purpose) for every DNS name the plan uses, website first."""
    names = []
    for settings in plan['instances']:
        website = settings.get('website') or {}
        if website.get('domain'):
            names.append((website['domain'], 'website'))
            names.extend((alias, 'website, redirects to ' + website['domain']) for alias in website.get('aliases', []))
    for settings in plan['instances']:
        if settings.get('address'):
            names.append((settings['address'], 'game server ' + settings['name']))
    unique = []
    for name, purpose in names:
        if name not in [existing for existing, _ in unique]:
            unique.append((name, purpose))
    return unique


def resolve(name):
    """{'A': {...}, 'AAAA': {...}} as this machine's resolver sees it now."""
    found = {'A': set(), 'AAAA': set()}
    try:
        for family, _, _, _, address in socket.getaddrinfo(name, None, proto=socket.IPPROTO_TCP):
            found['A' if family == socket.AF_INET else 'AAAA'].add(address[0])
    except socket.gaierror:
        pass
    return found


def problems(name, addresses):
    """What is wrong with one name; an empty list means it points here."""
    found = resolve(name)
    result = []
    if not found['A']:
        result.append('has no A record')
    elif not found['A'] <= set(addresses['A']):
        result.append('A record points to ' + ', '.join(sorted(found['A'])) + ', not here')
    # Let's Encrypt prefers IPv6: a wrong AAAA record breaks certificates even when A is right.
    wrong_ipv6 = found['AAAA'] - set(addresses['AAAA'])
    if wrong_ipv6:
        result.append('AAAA record points to ' + ', '.join(sorted(wrong_ipv6)) + ', not here (remove or fix it)')
    return result


def print_records(plan):
    """The records to create at the domain's DNS provider."""
    names = wanted_names(plan)
    if not names:
        return
    addresses = public_addresses(plan)
    print('\nDNS records to create at your domain provider (they can take minutes to hours to spread):',
          flush=True)
    for name, purpose in names:
        for address in addresses['A']:
            print(f'  {name:32} A     {address:39} ({purpose})', flush=True)
        for address in addresses['AAAA']:
            print(f'  {name:32} AAAA  {address:39} (optional, IPv6)', flush=True)
    if not addresses['A']:
        print('  (No public IPv4 address found yet.)', flush=True)


def report(plan):
    """One line per name: OK, or what is still wrong. Returns the website names that are not ready."""
    addresses = public_addresses(plan)
    flush_resolver_cache()
    pending = []
    for name, purpose in wanted_names(plan):
        issues = problems(name, addresses)
        print(f'  {name:32} ' + ('OK' if not issues else '; '.join(issues)) + f'  ({purpose})', flush=True)
        if issues and purpose.startswith('website'):
            pending.append(name)
    return pending


def flush_resolver_cache():
    """A record created a minute ago must not be hidden by a cached 'not found'."""
    subprocess.run(['resolvectl', 'flush-caches'], capture_output=True, timeout=30)


def wait_for_website_dns(plan):
    """Before the website starts: HTTPS certificates need every website name to point here.

    Interactive runs wait until the records are right (or the operator continues anyway;
    the certificate is then fetched automatically once DNS is right). Unattended runs
    only report.
    """
    if not wanted_names(plan):
        return
    print('\nChecking DNS...', flush=True)
    while True:
        pending = report(plan)
        if not pending or not sys.stdin.isatty():
            return
        print('HTTPS certificates are issued only once every website name points to this machine.'
              ' Using a DNS proxy such as Cloudflare? Set these records to "DNS only": game traffic cannot'
              ' pass its proxy, and this check sees the proxy\'s address instead of this machine.', flush=True)
        if ask('Check again, or continue (HTTPS starts by itself once DNS is right)? check / continue', 'check',
               choices=('check', 'continue')) == 'continue':
            return


def show(plan):
    """`opencj dns`: the records to create and their current state."""
    if not wanted_names(plan):
        print('No website domain or server address is configured. Set them with: sudo opencj configure NAME')
        return
    print_records(plan)
    print('\nCurrent state:', flush=True)
    report(plan)
