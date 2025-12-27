// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8;

// 合约开发：基于以太坊或其他主流区块链平台，使用 Solidity 或其他智能合约开发语言，实现一个 SHIB 风格的 Meme 代币合约。合约需包含以下功能：
// 代币税功能：实现交易税机制，对每笔代币交易征收一定比例的税费，并将税费分配给特定的地址或用于特定的用途。
// 流动性池集成：设计并实现与流动性池的交互功能，支持用户向流动性池添加和移除流动性。
// 交易限制功能：设置合理的交易限制，如单笔交易最大额度、每日交易次数限制等，防止恶意操纵市场。

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

contract MySHIB is ERC20, Ownable {
    address public taxReceiver; // 设置税费接收地址
    uint256 public maxTransactionRate; // 设置单笔最大交易的税率
    uint256 public maxDailyTransactionLimit; // 设置每日交易次数限制次数
    uint256 public RATIO_DENOMINATOR = 10000; // 设置税率分母为100，便于计算百分比
    // 设置滑点值
    uint256 public slippage;

    // 设置买入比例
    uint256 public buyRatio;
    // 设置卖出比例
    uint256 public sellRatio;
    // 设置初始铸币量
    uint256 public initialSupply;

    mapping(address => mapping(uint256 => uint256)) public dailyTransactions; // 记录每日交易次数

    mapping(address => bool) public isBlacklisted; // 看下地址是否在黑名单内


    // 设置交易账号
    address public uniswapV2Pair;
    address public uniswapV2Router;
    // 流动性是否初始化
    bool public liquidityPoolInitialized = false;

    // 检查转账地址是否为LP地址
    mapping(address => bool) public isLP;

    event TaxCollected(address indexed from, address indexed to, uint256 amount, bool isBuy);
    event LiquidityAdded(address indexed provider, uint256 tokenAmount, uint256 ethAmount, uint256 lpTokens);
    event LiquidityRemoved(address indexed provider, uint256 lpTokenAmount, uint256 tokenAmount, uint256 ethAmount);
    event LimitsUpdated(uint256 maxTransactionRate, uint256 maxDailyLimit);
    event TaxRatesUpdated(uint256 buyRatio, uint256 sellRatio);
    event Blacklisted(address account, bool result);

    constructor(
        address _taxReceiver,
        address _uniswapV2Router
    ) ERC20("MySHIB", "MySHIB") Ownable(msg.sender){ 
        initialSupply = 1000000 * (10 ** uint256(decimals()));
        _mint(msg.sender, initialSupply); // 初始铸币给合约部署者
        taxReceiver = _taxReceiver; // 设置税费接收地址
        maxTransactionRate = 100;
        maxDailyTransactionLimit = 10;
        buyRatio = 100; 
        sellRatio = 500; 
        uniswapV2Router = _uniswapV2Router; // 设置Uniswap V2 Router地址
        // 设置滑点值
        slippage = 9800;
    }

    // 移除构造函数中的自动创建，改为手动触发
function createPair() external onlyOwner {
    require(!liquidityPoolInitialized, "Pair already created");
    IUniswapV2Router02 router = IUniswapV2Router02(uniswapV2Router);
    address factory = router.factory();
    
    // 检查是否已存在配对
    uniswapV2Pair = IUniswapV2Factory(factory).getPair(address(this), router.WETH());
    if (uniswapV2Pair == address(0)) {
        // 创建新配对
        uniswapV2Pair = IUniswapV2Factory(factory).createPair(address(this), router.WETH());
    }
    
    isLP[uniswapV2Pair] = true;
    liquidityPoolInitialized = true;
}

    function checkParam(address sender, uint256 amount) internal  {
        // 检查交易金额是否超过最大额度
        uint256 maxSingleAmount = (initialSupply * maxTransactionRate) / RATIO_DENOMINATOR;
        require(
            amount <= maxSingleAmount,
            "Exceed maximum transaction amount"
        ); 
        // 检查是否超过当日交易次数
        uint256 dailyCount = dailyTransactions[_msgSender()][getDayTimestamp()]; 
        require(
            dailyCount < maxDailyTransactionLimit,
            "Exceeded daily transaction limit"
        );
        // 更新每日交易次数记录
        dailyTransactions[_msgSender()][getDayTimestamp()]++;
    }
    
    // 重写转账ERC20 转账函数，实现交易税功能
    function transfer(
        address to,
        uint256 amount
    ) public virtual override returns (bool) {
        // 检查地址是否在黑名单中
        require(!isBlacklisted[_msgSender()], "Sender is blacklisted");
        require(!isBlacklisted[to], "Recipient is blacklisted");
        
        checkParam(_msgSender(), amount);
        
        // 检查是否为LP交易
        bool isLpTransaction = (to == uniswapV2Pair || _msgSender() == uniswapV2Pair);
        
        // 如果是卖出，进行额外检查
        if (to == uniswapV2Pair) {
            require(!isLP[_msgSender()], "LP cannot sell");
        }
        
        // 只有LP交易才收取手续费
        if (isLpTransaction) {
            bool isBuy = _isBuyOrSell(_msgSender(), to);
            (uint256 taxAmount, uint256 value) = computeTax(amount, isBuy);
            _transfer(_msgSender(), to, value);
            _transfer(_msgSender(), taxReceiver, taxAmount);
            emit TaxCollected(_msgSender(), taxReceiver, taxAmount, isBuy);
        } else {
            // 普通用户间转账免手续费
            _transfer(_msgSender(), to, amount);
        }
        
        return true;
    }
    
    // 重写转账ERC20 转账函数，实现交易税功能
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public virtual override returns (bool) {
        // 检查地址是否在黑名单中
        require(!isBlacklisted[from], "Sender is blacklisted");
        require(!isBlacklisted[to], "Recipient is blacklisted");
        
        // 检查参数
        checkParam(from, amount);

        require(!isLP[to], "Cannot transfer to LP address");

        // 扣除授权额度
        _spendAllowance(from, _msgSender(), amount);
        // 更新每日交易次数记录
        dailyTransactions[from][getDayTimestamp()]++;
        
        // 检查是否为LP交易
        bool isLpTransaction = (to == uniswapV2Pair || from == uniswapV2Pair);
        
        // 只有LP交易才收取手续费
        if (isLpTransaction) {
            bool isBuy = _isBuyOrSell(from, to);
            (uint256 taxAmount, uint256 value) = computeTax(amount, isBuy);
            _transfer(from, to, value);
            _transfer(from, taxReceiver, taxAmount);
            emit TaxCollected(from, taxReceiver, taxAmount, isBuy);
        } else {
            // 普通用户间转账免手续费
            _transfer(from, to, amount);
        }
        
        return true;
    }
    // 获取每日的时间戳标识，用于记录每日交易次数
    function getDayTimestamp() public view returns (uint256) {
        // 每86400秒（1天）为一个时间戳标识
        return block.timestamp - (block.timestamp % 86400); 
    }

    // 计算税率。
    function computeTax(uint256 amount, bool isBuy) public view returns (uint256, uint256) {
        uint256 taxRate = isBuy ? buyRatio : sellRatio;
        uint256 tax = (amount * taxRate) / RATIO_DENOMINATOR;
        return (tax, amount - tax);
    }

    //判断是买入还是卖出
    function _isBuyOrSell(address from, address to) public view returns (bool isBuy) {
        require(uniswapV2Pair != address(0), "Pair not initialized");
        // 买入：从LP配对合约转到普通地址
        isBuy = (from == uniswapV2Pair && to != uniswapV2Pair);
    }

  
    // 添加权限控制函数
    function setTaxReceiver(address _taxReceiver) external onlyOwner {
        require(_taxReceiver != address(0), "Invalid tax receiver");
        taxReceiver = _taxReceiver;
    }
    
    function setTaxRates(uint256 _buyRatio, uint256 _sellRatio) external onlyOwner {
        require(_buyRatio <= 1000, "Buy tax too high"); // 最大10%
        require(_sellRatio <= 1000, "Sell tax too high"); // 最大10%
        buyRatio = _buyRatio;
        sellRatio = _sellRatio;
        emit TaxRatesUpdated(_buyRatio, _sellRatio);
    }
    
    function setTransactionLimits(uint256 _maxTransactionRate, uint256 _maxDailyLimit) external onlyOwner {
        maxTransactionRate = _maxTransactionRate;
        maxDailyTransactionLimit = _maxDailyLimit;
        emit LimitsUpdated(_maxTransactionRate, _maxDailyLimit);
    }
    
    // 黑名单管理函数
    function setBlacklist(address account, bool blacklisted) external onlyOwner {
        isBlacklisted[account] = blacklisted;
        emit Blacklisted(account, blacklisted);
    }
    
    // 批量黑名单管理函数
    function setMultipleBlacklist(address[] memory accounts, bool blacklisted) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; i++) {
            isBlacklisted[accounts[i]] = blacklisted;
            emit Blacklisted(accounts[i], blacklisted);
        }
    }

    /**
     * @dev 向流动性池添加流动性（ETH-代币配对）
     * @param tokenAmount 代币数量
     * @return lpTokensReceived 获得的LP代币数量
     */
    function addLiquidity(uint256 tokenAmount) external payable returns (uint256 lpTokensReceived) {
        require(tokenAmount > 0, "Token amount cannot be zero");
        require(msg.value > 0, "ETH amount cannot be zero");
        
        // 转账代币到合约
        _transfer(msg.sender, address(this), tokenAmount);
        
        // 授权Uniswap路由使用代币
        _approve(address(this), uniswapV2Router, tokenAmount);
        
        // 调用Uniswap路由添加流动性
        (,, uint256 liquidity) = IUniswapV2Router02(uniswapV2Router).addLiquidityETH{value: msg.value}(
            address(this),
            tokenAmount,
            tokenAmount * slippage / RATIO_DENOMINATOR, // 最小接收代币数量
            msg.value * slippage / RATIO_DENOMINATOR, // 最小接收ETH数量
            msg.sender,
            block.timestamp + 1800 // 30分钟过期
        );
        
        require(liquidity > 0, "Failed to add liquidity");
            emit LiquidityAdded(msg.sender, tokenAmount, msg.value, liquidity);
        return liquidity;
    }

    /**
     * @dev 从流动性池移除流动性（ETH-代币配对）
     * @param lpTokenAmount 要移除的LP代币数量
     * @param minTokenAmount 最小接收代币数量（滑点保护）
     * @param minETHAmount 最小接收ETH数量（滑点保护）
     * @return tokenAmountReceived 实际收到的代币数量
     * @return ethAmountReceived 实际收到的ETH数量
     */
    function removeLiquidity(
        uint256 lpTokenAmount,
        uint256 minTokenAmount,
        uint256 minETHAmount
    ) external returns (uint256 tokenAmountReceived, uint256 ethAmountReceived) {
        require(lpTokenAmount > 0, "LP token amount cannot be zero");
        
        // 转移LP代币到合约
        IUniswapV2Pair(uniswapV2Pair).transferFrom(msg.sender, address(this), lpTokenAmount);
        
        // 授权Uniswap路由使用LP代币
        IUniswapV2Pair(uniswapV2Pair).approve(uniswapV2Router, lpTokenAmount);
        
        // 调用Uniswap路由移除流动性
        (tokenAmountReceived, ethAmountReceived) = IUniswapV2Router02(uniswapV2Router).removeLiquidityETH(
            address(this),
            lpTokenAmount,
            minTokenAmount, // 最小接收代币数量
            minETHAmount,   // 最小接收ETH数量
            msg.sender,     // 代币和ETH接收地址
            block.timestamp + 1800 // 30分钟过期
        );
        
        require(tokenAmountReceived >= minTokenAmount, "Token amount below minimum");
        require(ethAmountReceived >= minETHAmount, "ETH amount below minimum");
        emit LiquidityRemoved(msg.sender, lpTokenAmount, tokenAmountReceived, ethAmountReceived);
    }

    /**
     * @dev 获取用户的LP代币余额
     * @param user 用户地址
     * @return lpBalance LP代币余额
     */
    function getLPTokenBalance(address user) external view returns (uint256 lpBalance) {
        return IUniswapV2Pair(uniswapV2Pair).balanceOf(user);
    }

    /**
     * @dev 获取流动性池储备信息
     * @return tokenReserve 代币储备量
     * @return ethReserve ETH储备量
     */
    function getPoolReserves() external view returns (uint256 tokenReserve, uint256 ethReserve) {
        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(uniswapV2Pair).getReserves();
        address token0 = IUniswapV2Pair(uniswapV2Pair).token0();
        if (token0 == address(this)) {
            return (reserve0, reserve1);
        } else {
            return (reserve1, reserve0);
        }
    }
}
