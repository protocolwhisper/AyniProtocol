// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "./interfaces/IERC20.sol";
import {IAyniClaimOrigin} from "./interfaces/IAyniClaimOrigin.sol";
import {IDestinationSettler} from "./intents/ERC7683.sol";
import {SafeERC20} from "./utils/SafeERC20.sol";

contract AyniDestinationSettler is IDestinationSettler {
    using SafeERC20 for IERC20;

    struct FillOriginData {
        address recipient;
        address debt_asset;
        uint256 amount;
    }

    IAyniClaimOrigin public immutable origin_settler;

    constructor(address origin_settler_) {
        require(origin_settler_ != address(0), "DestinationSettler: bad origin");
        origin_settler = IAyniClaimOrigin(origin_settler_);
    }

    function fill(bytes32 orderId, bytes calldata originData, bytes calldata) external {
        FillOriginData memory fill_data = abi.decode(originData, (FillOriginData));
        require(fill_data.recipient != address(0), "DestinationSettler: bad recipient");

        IERC20(fill_data.debt_asset).safeTransferFrom(msg.sender, fill_data.recipient, fill_data.amount);

        origin_settler.confirm_fill(orderId, msg.sender, originData);
    }
}
