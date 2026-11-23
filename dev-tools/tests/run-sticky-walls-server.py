#!/usr/bin/env python3
"""Probe wall geometry on isolated servers; native comparisons require an instrumented binary."""

from sticky_wall_fixture import parse_options, run_probe


def main():
    options = parse_options()
    for map_name in options.maps:
        run_probe(options, map_name)


if __name__ == "__main__":
    main()
