// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.24;

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC721Metadata} from "openzeppelin-contracts/contracts/token/ERC721/extensions/IERC721Metadata.sol";

import {IAddressesRegistry} from "src/Interfaces/IAddressesRegistry.sol";
import {IMetadataNFT} from "src/Interfaces/IMetadataNFT.sol";
import {IJpydfToken} from "src/Interfaces/IJpydfToken.sol";
import {ITroveNFT} from "src/Interfaces/ITroveNFT.sol";
import {ITroveManager} from "src/Interfaces/ITroveManager.sol";
import {LatestTroveData} from "src/Types/LatestTroveData.sol";

contract JPYdfTroveNFT is ERC721, ITroveNFT {
    error JPYdfTroveNFT__CallerIsNotTroveManager();

    ITroveManager public immutable troveManager;
    IERC20Metadata internal immutable collToken;
    IJpydfToken internal immutable jpydfToken;

    IMetadataNFT public immutable metadataNFT;

    constructor(IAddressesRegistry _addressesRegistry)
        ERC721(
            string.concat("JPYdf - ", _addressesRegistry.collToken().name()),
            string.concat("JPYdf_", _addressesRegistry.collToken().symbol())
        )
    {
        troveManager = _addressesRegistry.troveManager();
        collToken = _addressesRegistry.collToken();
        metadataNFT = _addressesRegistry.metadataNFT();
        jpydfToken = _addressesRegistry.jpydfToken();
    }

    function tokenURI(uint256 _tokenId) public view override(ERC721, IERC721Metadata) returns (string memory) {
        LatestTroveData memory latestTroveData = troveManager.getLatestTroveData(_tokenId);

        IMetadataNFT.TroveData memory troveData = IMetadataNFT.TroveData({
            _tokenId: _tokenId,
            _owner: ownerOf(_tokenId),
            _collToken: address(collToken),
            _jpydfToken: address(jpydfToken),
            _collAmount: latestTroveData.entireColl,
            _debtAmount: latestTroveData.entireDebt,
            _interestRate: latestTroveData.annualInterestRate,
            _status: troveManager.getTroveStatus(_tokenId)
        });

        return metadataNFT.uri(troveData);
    }

    function mint(address _owner, uint256 _troveId) external override {
        _requireCallerIsTroveManager();
        _mint(_owner, _troveId);
    }

    function burn(uint256 _troveId) external override {
        _requireCallerIsTroveManager();
        _burn(_troveId);
    }

    function _requireCallerIsTroveManager() internal view {
        if (msg.sender != address(troveManager)) revert JPYdfTroveNFT__CallerIsNotTroveManager();
    }
}
