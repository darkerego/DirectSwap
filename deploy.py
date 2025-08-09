#!/usr/bin/env python3
import asyncio
import os
import shlex
import dotenv

dotenv.load_dotenv()

BASS_HTTP_ENDPOINT = os.environ.get('BASS_HTTP_ENDPOINT', False)
PRIVATE_KEY = os.environ.get('PRIVATE_KEY', False)
ETHERSCAN_API_KEY = os.environ.get('ETHERSCAN_API_KEY', False)
try:
     assert PRIVATE_KEY and BASS_HTTP_ENDPOINT and ETHERSCAN_API_KEY
except AssertionError as err:
    print(f'[!] Please configure your .env: {err}')
    exit(1)
OPT_RUNS = 200


class Deployer:
    @classmethod
    async def deploy(cls):
        args = shlex.split(
            f'create --rpc-url {BASS_HTTP_ENDPOINT} --private-key {PRIVATE_KEY} --broadcast --etherscan-api-key {ETHERSCAN_API_KEY} --verify --verifier etherscan --optimize --optimizer-runs {200} .contracts/DirectSwap.sol:UniswapDirectSwap')
        proc = await asyncio.create_subprocess_exec('forge', *args, stdout=asyncio.subprocess.PIPE,
                                                    stderr=asyncio.subprocess.PIPE)
        stdout, stderr = await proc.communicate()
        print(stdout.decode())
        print(stderr.decode())
        await proc.wait()

    @classmethod
    async def main(cls):
        print('[*] Deploying contract in 3 secs ... please ensure you have forge installed or else this will fail!')
        await asyncio.sleep(3)
        return await Deployer.deploy()


if __name__ == '__main__':
    asyncio.run(Deployer.main())