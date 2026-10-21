import json
import os
from pathlib import Path


SIGNING_NAMES = ('ANDROID_KEYSTORE_BASE64', 'ANDROID_KEYSTORE_PASSWORD',
                 'ANDROID_KEY_ALIAS', 'ANDROID_KEY_PASSWORD')


def availability(environment):
    present = {name: bool(environment.get(name)) for name in SIGNING_NAMES}
    return {'ok': all(present.values()), 'configured': present,
            'existingSecretsOnly': True, 'newKeyGenerated': False}


def main():
    result = availability(os.environ)
    directory = Path(__file__).resolve().parents[1] / 'dist/android'
    directory.mkdir(parents=True, exist_ok=True)
    (directory / 'Signing-availability.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))
    if not result['ok']:
        raise SystemExit('Existing Android signing Secrets are incomplete; no new key will be generated.')


if __name__ == '__main__':
    main()
