#!/usr/bin/env python3
"""Read release identity from the app target, never from an arbitrary pbxproj line."""
import json
from pathlib import Path
import re
import subprocess


def release_metadata(project):
    objects = project['objects']
    targets = [obj for obj in objects.values()
               if obj.get('isa') == 'PBXNativeTarget' and obj.get('name') == 'macshot']
    if len(targets) != 1:
        raise ValueError('Expected exactly one macshot application target')
    configs = objects[targets[0]['buildConfigurationList']]['buildConfigurations']
    releases = [objects[key]['buildSettings'] for key in configs if objects[key]['name'] == 'Release']
    if len(releases) != 1:
        raise ValueError('Expected exactly one application Release configuration')
    settings = releases[0]
    if settings.get('PRODUCT_BUNDLE_IDENTIFIER') != 'com.itvx.macshot':
        raise ValueError('Release bundle identifier must belong to this fork')
    version = str(settings.get('MARKETING_VERSION', ''))
    build = str(settings.get('CURRENT_PROJECT_VERSION', ''))
    if not re.fullmatch(r'[0-9]+(?:\.[0-9]+){1,2}', version):
        raise ValueError('Invalid application release version')
    if not re.fullmatch(r'[0-9]+', build) or int(build) < 900003:
        raise ValueError('Application build base must preserve the fork update sequence')
    return version, build


if __name__ == '__main__':
    path = Path(__file__).resolve().parent.parent / 'macshot.xcodeproj/project.pbxproj'
    raw = subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)])
    print(*release_metadata(json.loads(raw)))
