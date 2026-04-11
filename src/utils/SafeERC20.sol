// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "../interfaces/IERC20.sol";

library SafeERC20 {
    function safeTransfer(IERC20 token, address to, uint256 amount) internal {
        _callOptionalReturn(token, abi.encodeCall(IERC20.transfer, (to, amount)), "SafeERC20: transfer failed");
    }

    function safeTransferFrom(IERC20 token, address from_, address to, uint256 amount) internal {
        _callOptionalReturn(
            token, abi.encodeCall(IERC20.transferFrom, (from_, to, amount)), "SafeERC20: transferFrom failed"
        );
    }

    function _callOptionalReturn(IERC20 token, bytes memory data, string memory error_message) private {
        (bool success, bytes memory returndata) = address(token).call(data);
        require(
            success && (returndata.length == 0 || abi.decode(returndata, (bool))),
            error_message
        );
    }
}
