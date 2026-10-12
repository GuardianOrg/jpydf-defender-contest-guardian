// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IMetadataNFT} from "src/Interfaces/IMetadataNFT.sol";
import {ITroveManager} from "src/Interfaces/ITroveManager.sol";
import {FixedAssetReader} from "src/NFTMetadata/utils/FixedAssets.sol";
import {JPYdfBaseSVG} from "src/NFTMetadata/utils/JPYdfBaseSVG.sol";
import {json} from "src/NFTMetadata/utils/JSON.sol";
import {svg} from "src/NFTMetadata/utils/SVG.sol";
import {LibString} from "src/NFTMetadata/utils/Utils.sol";
import {bauhaus} from "src/NFTMetadata/utils/bauhaus.sol";

contract JPYdfMetadataNFT is IMetadataNFT {
    FixedAssetReader public immutable assetReader;

    constructor(FixedAssetReader _assetReader) {
        assetReader = _assetReader;
    }

    function uri(TroveData memory _troveData) public view returns (string memory) {
        string memory attr = attributes(_troveData);
        return json.formattedMetadata(
            string.concat("JPYdf - ", IERC20Metadata(_troveData._collToken).name()),
            string.concat(
                "JPYdf is a collateralized debt protocol. Users can lock up ",
                IERC20Metadata(_troveData._collToken).symbol(),
                " to mint JPYdf. The individual collateralized debt positions are called Troves and are represented as NFTs."
            ),
            renderSVGImage(_troveData),
            attr
        );
    }

    function renderSVGImage(TroveData memory _troveData) internal view returns (string memory) {
        return svg._svg(
            JPYdfBaseSVG._svgProps(),
            string.concat(
                JPYdfBaseSVG._baseElements(assetReader),
                bauhaus._bauhaus(IERC20Metadata(_troveData._collToken).symbol(), _troveData._tokenId),
                dynamicTextComponents(_troveData)
            )
        );
    }

    function attributes(TroveData memory _troveData) public pure returns (string memory) {
        return string.concat(
            '[{"trait_type": "Collateral Token", "value": "',
            LibString.toHexString(_troveData._collToken),
            '"}, {"trait_type": "Collateral Amount", "value": "',
            LibString.toString(_troveData._collAmount),
            '"}, {"trait_type": "Debt Token", "value": "',
            LibString.toHexString(_troveData._jpydfToken),
            '"}, {"trait_type": "Debt Amount", "value": "',
            LibString.toString(_troveData._debtAmount),
            '"}, {"trait_type": "Interest Rate", "value": "',
            LibString.toString(_troveData._interestRate),
            '"}, {"trait_type": "Status", "value": "',
            _status2Str(_troveData._status),
            '"} ]'
        );
    }

    function dynamicTextComponents(TroveData memory _troveData) public view returns (string memory) {
        string memory id = LibString.toHexString(_troveData._tokenId);
        id = string.concat(LibString.slice(id, 0, 6), "...", LibString.slice(id, 38, 42));

        return string.concat(
            JPYdfBaseSVG._formattedIdEl(id),
            JPYdfBaseSVG._formattedAddressEl(_troveData._owner),
            JPYdfBaseSVG._collLogo(IERC20Metadata(_troveData._collToken).symbol(), assetReader),
            JPYdfBaseSVG._statusEl(_status2Str(_troveData._status)),
            JPYdfBaseSVG._dynamicTextEls(_troveData._debtAmount, _troveData._collAmount, _troveData._interestRate)
        );
    }

    function _status2Str(ITroveManager.Status status) internal pure returns (string memory) {
        if (status == ITroveManager.Status.active) return "Active";
        if (status == ITroveManager.Status.closedByOwner) return "Closed";
        if (status == ITroveManager.Status.closedByLiquidation) return "Liquidated";
        if (status == ITroveManager.Status.zombie) return "Below Min Debt";
        return "";
    }
}
