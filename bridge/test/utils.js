const BN = web3.utils.BN;

const GAS_LIMIT = 6800000;
const ADDRESS_LENGTH = 20;
const HASH_LENGTH = 32;
const randomHex = web3.utils.randomHex;

const saveState = async () =>
  new Promise((resolve) => {
    web3.currentProvider.send(
      {
        jsonrpc: "2.0",
        method: "evm_snapshot",
        id: 0,
      },
      (error, res) => {
        const result = parseInt(res.result, 0);
        lastSnapshot = result;
        resolve(result);
      }
    );
  });

const revertState = async () => {
  await new Promise((resolve) =>
    web3.currentProvider.send(
      {
        jsonrpc: "2.0",
        method: "evm_revert",
        params: lastSnapshot,
        id: 0,
      },
      (error, res) => {
        resolve(res.result);
      }
    )
  );

  //lastSnapshot = await saveState();
};

// from https://ethereum.stackexchange.com/questions/11444/web3-js-with-promisified-api
const promisify = (inner) =>
  new Promise((resolve, reject) =>
    inner((err, res) => {
      if (err) {
        reject(err);
      }

      resolve(res);
    })
  );

function checkGas(gas) {
  //process.stdout.write(`\x1b[36m[Gas:${gas}]\x1b[0m`);
  assert(gas < GAS_LIMIT, "Gas used bigger than the maximum in mainnet");
}

function checkRcpt(tx) {
  assert.equal(Number(tx.receipt.status), 1, "Should be a succesful Tx");
  checkGas(tx.receipt.gasUsed);
}

/**
 * @type {function}
 * @param {{
 *  tx: string,
 *  receipt: {
 *    gasUsed: number
 *  }
 * }} tx - is an object returned from the smartcontract tx
 * @returns {BN} the gas used multiplied by the gas price
 */
const getGasUsedByTx = async (tx) => {
  const gasUsed = new BN(tx.receipt.gasUsed);

  const txWithPrice = await web3.eth.getTransaction(tx.tx);
  const gasPrice = new BN(txWithPrice.gasPrice);

  return gasUsed.mul(gasPrice);
};

/**
 * @type {function}
 * @param {string} address - addr to check the amount of ether
 * @returns {BN} - the ether balance of address
 */
const getEtherBalance = async (address) => {
  return new BN(await web3.eth.getBalance(address));
};

const asyncMine = async () => {
  return new Promise((resolve, reject) => {
    web3.currentProvider.send(
      {
        jsonrpc: "2.0",
        method: "evm_mine",
        id: new Date().getTime(),
      },
      (error, result) => {
        if (error) {
          return reject(error);
        }
        return resolve(result);
      }
    );
  });
};

let evm_mine = async (iterations) => {
  for (var i = 0; i < iterations; i++) {
    await asyncMine();
  }
};

function increaseTimestamp(web3, increase) {
  return new Promise((resolve, reject) => {
    web3.currentProvider.send(
      {
        method: "evm_increaseTime",
        params: [increase],
        jsonrpc: "2.0",
        id: new Date().getTime(),
      },
      (error, result) => {
        if (error) {
          return reject(error);
        }
        return asyncMine().then(() => resolve(result));
      }
    );
  });
}

function stripHexPrefix(hexString) {
  if (hexString.substring(0, 2).toLowerCase() === "0x") {
    hexString = hexString.substring(2);
  }
  return hexString;
}

function calculatePrefixesSuffixes(nodes) {
  const prefixes = [];
  const suffixes = [];
  const ns = [];

  for (let i = 0; i < nodes.length; i++) {
    nodes[i] = stripHexPrefix(nodes[i]);
  }

  for (let k = 0, l = nodes.length; k < l; k++) {
    if (k + 1 < l && nodes[k + 1].indexOf(nodes[k]) >= 0) {
      continue;
    }

    ns.push(nodes[k]);
  }

  let hash = web3.utils.sha3(Buffer.from(ns[0], "hex"));
  hash = stripHexPrefix(hash);

  prefixes.push("0x");
  suffixes.push("0x");

  for (let k = 1, l = ns.length; k < l; k++) {
    const p = ns[k].indexOf(hash);

    prefixes.push("0x" + ns[k].substring(0, p));
    suffixes.push("0x" + ns[k].substring(p + hash.length));

    hash = web3.utils.sha3(Buffer.from(ns[k], "hex"));
    hash = stripHexPrefix(hash);
  }
  return { prefixes: prefixes, suffixes: suffixes };
}

function ascii_to_hexa(str) {
  var arr1 = [];
  for (var n = 0, l = str.length; n < l; n++) {
    var hex = Number(str.charCodeAt(n)).toString(16);
    arr1.push(hex);
  }
  return "0x" + arr1.join("");
}

function getRandomAddress() {
  return randomHex(ADDRESS_LENGTH);
}

function getRandomHash() {
  return randomHex(HASH_LENGTH);
}

const tokenType = {
  COIN: 0,
  NFT: 1
};

module.exports = {
  getEtherBalance: getEtherBalance,
  getGasUsedByTx: getGasUsedByTx,
  checkGas: checkGas,
  checkRcpt: checkRcpt,
  evm_mine: evm_mine,
  promisify: promisify,
  calculatePrefixesSuffixes: calculatePrefixesSuffixes,
  increaseTimestamp: increaseTimestamp,
  ascii_to_hexa: ascii_to_hexa,
  NULL_ADDRESS: "0x0000000000000000000000000000000000000000",
  NULL_HASH:
    "0x0000000000000000000000000000000000000000000000000000000000000000",
  saveState: saveState,
  revertState: revertState,
  getRandomAddress: getRandomAddress,
  getRandomHash: getRandomHash,
  tokenType,
};
