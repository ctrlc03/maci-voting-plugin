import {PLUGIN_CONTRACT_NAME} from '../../plugin-settings';
import {
  DAOMock,
  DAOMock__factory,
  MaciVoting,
  MaciVotingPluginSetup__factory,
} from '../../typechain';
import '../../typechain/src/MyPlugin';
import {loadFixture} from '@nomicfoundation/hardhat-network-helpers';
import {SignerWithAddress} from '@nomiclabs/hardhat-ethers/signers';
import {expect} from 'chai';
import {BigNumber} from 'ethers';
import {ethers, upgrades} from 'hardhat';

export type InitData = {number: BigNumber};
export const defaultInitData: InitData = {
  number: BigNumber.from(123),
};

export const STORE_PERMISSION_ID = ethers.utils.id('STORE_PERMISSION');

type FixtureResult = {
  deployer: SignerWithAddress;
  alice: SignerWithAddress;
  bob: SignerWithAddress;
  plugin: MaciVoting;
  daoMock: DAOMock;
};

async function fixture(): Promise<FixtureResult> {
  const [deployer, alice, bob] = await ethers.getSigners();
  const daoMock = await new DAOMock__factory(deployer).deploy();
  const plugin = (await upgrades.deployProxy(
    new MaciVotingPluginSetup__factory(deployer),
    [daoMock.address, defaultInitData.number],
    {
      kind: 'uups',
      initializer: 'initialize',
      unsafeAllow: ['constructor'],
      constructorArgs: [],
    }
  )) as unknown as MaciVoting;

  return {deployer, alice, bob, plugin, daoMock};
}

describe(PLUGIN_CONTRACT_NAME, function () {
  describe('initialize', async () => {
    it('reverts if trying to re-initialize', async () => {
      const {plugin, daoMock} = await loadFixture(fixture);
      await expect(
        plugin.initialize(daoMock.address, defaultInitData.number)
      ).to.be.revertedWith('Initializable: contract is already initialized');
    });
  });
});
