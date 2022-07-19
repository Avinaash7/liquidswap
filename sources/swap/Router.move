/// Router for Liquidity Pool, similar to Uniswap router.
module MultiSwap::Router {
    // !!! FOR AUDITOR!!!
    // Look at math part of this contract.
    use Std::Errors;

    use AptosFramework::Coin::{Coin, Self};

    use MultiSwap::CoinHelper::{Self, supply};
    use MultiSwap::LiquidityPool;
    use MultiSwap::Math;
    use MultiSwap::StableCurve;

    // Errors codes.

    /// Wrong amount used.
    const ERR_WRONG_AMOUNT: u64 = 100;
    /// Wrong reserve used.
    const ERR_WRONG_RESERVE: u64 = 101;
    /// Insuficient amount in Y reserves.
    const ERR_INSUFFICIENT_Y_AMOUNT: u64 = 102;
    /// Insuficient amount in X reserves.
    const ERR_INSUFFICIENT_X_AMOUNT: u64 = 103;
    /// Overlimit of X coins to swap.
    const ERR_OVERLIMIT_X: u64 = 104;
    /// Amount out less than minimum.
    const ERR_COIN_OUT_NUM_LESS_THAN_EXPECTED_MINIMUM: u64 = 105;
    /// Needed amount in great than maximum.
    const ERR_COIN_VAL_MAX_LESS_THAN_NEEDED: u64 = 106;

    const ERR_INVALID_CURVE: u64 = 110;

    const STABLE_CURVE: u8 = 1;
    const UNSTABLE_CURVE: u8 = 2;

    // Public functions.

    /// Check liquidity pool exists for coins `X` and `Y` at owner address.
    /// * `pool_addr` - pool owner address.
    public fun pool_exists_at<X, Y, LP>(pool_addr: address): bool {
        if (CoinHelper::is_sorted<X, Y>()) {
            LiquidityPool::pool_exists_at<X, Y, LP>(pool_addr)
        } else {
            LiquidityPool::pool_exists_at<Y, X, LP>(pool_addr)
        }
    }

    /// Register new liquidity pool for `X`/`Y` pair on signer address.
    /// * `lp_coin_mint_cap` - LP coin mint capability.
    /// * `lp_coin_burn_cap` - LP coin burn capability.
    public fun register_liquidity_pool<X, Y, LP>(account: &signer, correlation_curve_type: u8) {
        if (CoinHelper::is_sorted<X, Y>()) {
            let (lp_name, lp_symbol) = CoinHelper::generate_lp_name<X, Y>();
            LiquidityPool::register<X, Y, LP>(account, lp_name, lp_symbol, correlation_curve_type);
        } else {
            let (lp_name, lp_symbol) = CoinHelper::generate_lp_name<Y, X>();
            LiquidityPool::register<Y, X, LP>(account, lp_name, lp_symbol, correlation_curve_type);
        }
    }

    /// Add liquidity to pool `X`/`Y` without rationality checks.
    /// Call `calc_required_liquidity` to get optimal amounts first, and only use returned amount for `coin_x` and `coin_y`.
    /// * `pool_addr` - pool owner address.
    /// * `coin_x` - coins X used to add liquidity.
    /// * `coin_y` - coins Y used to add liquidity.
    public fun add_liquidity_inner<X, Y, LP>(pool_addr: address, coin_x: Coin<X>, coin_y: Coin<Y>): Coin<LP> {
        if (CoinHelper::is_sorted<X, Y>()) {
            LiquidityPool::add_liquidity<X, Y, LP>(pool_addr, coin_x, coin_y)
        } else {
            LiquidityPool::add_liquidity<Y, X, LP>(pool_addr, coin_y, coin_x)
        }
    }

    /// Add liquidity to pool `X`/`Y` with rationality checks.
    /// * `pool_addr` - pool owner address.
    /// * `coin_x` - coin X to add as liquidity.
    /// * `min_coin_x_val` - minimum amount of coin X to add as liquidity (slippage).
    /// * `coin_y` - coin Y to add as liquidity.
    /// * `min_coin_y_val` - minimum amount of coin Y to add as liquidity (slippage).
    public fun add_liquidity<X, Y, LP>(
        pool_addr: address,
        coin_x: Coin<X>,
        min_coin_x_val: u64,
        coin_y: Coin<Y>,
        min_coin_y_val: u64
    ): (Coin<X>, Coin<Y>, Coin<LP>) {
        let coin_x_val = Coin::value(&coin_x);
        let coin_y_val = Coin::value(&coin_y);

        let (optimal_x, optimal_y) =
            calc_optimal_coin_values<X, Y, LP>(
                pool_addr,
                coin_x_val,
                coin_y_val,
                min_coin_x_val,
                min_coin_y_val
            );

        let coin_x_opt = Coin::extract(&mut coin_x, optimal_x);
        let coin_y_opt = Coin::extract(&mut coin_y, optimal_y);
        let lp_coins = add_liquidity_inner<X, Y, LP>(pool_addr, coin_x_opt, coin_y_opt);

        (coin_x, coin_y, lp_coins)
    }

    /// Burn liquidity coins `LP` and get coins `X` and `Y` back.
    /// * `pool_addr` - pool owner address.
    /// * `lp_coins` - `LP` coins to burn.
    /// * `min_x_out_val` - minimum amount of `X` coins must be out.
    /// * `min_y_out_val` - minimum amount of `Y` coins must be out.
    /// Returns both coins `X` and `Y`.
    public fun remove_liquidity<X, Y, LP>(
        pool_addr: address,
        lp_coins: Coin<LP>,
        min_x_out_val: u64,
        min_y_out_val: u64
    ): (Coin<X>, Coin<Y>) {
        let (x_out, y_out) = if (CoinHelper::is_sorted<X, Y>()) {
            LiquidityPool::burn_liquidity<X, Y, LP>(pool_addr, lp_coins)
        } else {
            let (y, x) = LiquidityPool::burn_liquidity<Y, X, LP>(pool_addr, lp_coins);
            (x, y)
        };

        assert!(
            Coin::value(&x_out) >= min_x_out_val,
            Errors::invalid_argument(ERR_COIN_OUT_NUM_LESS_THAN_EXPECTED_MINIMUM)
        );
        assert!(
            Coin::value(&y_out) >= min_y_out_val,
            Errors::invalid_argument(ERR_COIN_OUT_NUM_LESS_THAN_EXPECTED_MINIMUM)
        );

        (x_out, y_out)
    }

    /// Swap exact amount of coin `X` for coin `Y`.
    /// * `pool_addr` - pool owner address.
    /// * `coin_in` - coin X to swap.
    /// * `coin_out_min_val` - minimum amount of coin Y to get out.
    public fun swap_exact_coin_for_coin<X, Y, LP>(
        pool_addr: address,
        coin_in: Coin<X>,
        coin_out_min_val: u64,
    ): Coin<Y> {
        let coin_in_val = Coin::value(&coin_in);
        let coin_out_val = get_amount_out<X, Y, LP>(pool_addr, coin_in_val);

        assert!(
            coin_out_val >= coin_out_min_val,
            Errors::invalid_argument(ERR_COIN_OUT_NUM_LESS_THAN_EXPECTED_MINIMUM),
        );

        let (zero, coin_out);
        if (CoinHelper::is_sorted<X, Y>()) {
            (zero, coin_out) = LiquidityPool::swap<X, Y, LP>(pool_addr, coin_in, 0, Coin::zero(), coin_out_val);
        } else {
            (coin_out, zero) = LiquidityPool::swap<Y, X, LP>(pool_addr, Coin::zero(), coin_out_val, coin_in, 0);
        };
        Coin::destroy_zero(zero);

        coin_out
    }

    /// Swap max coin amount `X` for exact coin `Y`.
    /// * `pool_addr` - pool owner address.
    /// * `coin_max_in` - maximum amount of coin X to swap to get `coin_out_val` of coins Y.
    /// * `coin_out_val` - exact amount of coin Y to get.
    public fun swap_coin_for_exact_coin<X, Y, LP>(
        pool_addr: address,
        coin_max_in: Coin<X>,
        coin_out_val: u64,
    ): (Coin<X>, Coin<Y>) {
        let coin_in_val_needed = get_amount_in<X, Y, LP>(pool_addr, coin_out_val);

        let coin_val_max = Coin::value(&coin_max_in);
        assert!(
            coin_in_val_needed <= coin_val_max,
            Errors::invalid_argument(ERR_COIN_VAL_MAX_LESS_THAN_NEEDED)
        );

        let coin_in = Coin::extract(&mut coin_max_in, coin_in_val_needed);

        let (zero, coin_out);
        if (CoinHelper::is_sorted<X, Y>()) {
            (zero, coin_out) = LiquidityPool::swap<X, Y, LP>(pool_addr, coin_in, 0, Coin::zero(), coin_out_val);
        } else {
            (coin_out, zero) = LiquidityPool::swap<Y, X, LP>(pool_addr, Coin::zero(), coin_out_val, coin_in, 0);
        };
        Coin::destroy_zero(zero);

        (coin_max_in, coin_out)
    }

    // Getters.

    /// Get reserves of liquidity pool (`X` and `Y`).
    /// * `pool_addr` - pool owner address.
    /// Returns current reserves.
    public fun get_reserves_size<X, Y, LP>(pool_addr: address): (u64, u64) {
        if (CoinHelper::is_sorted<X, Y>()) {
            LiquidityPool::get_reserves_size<X, Y, LP>(pool_addr)
        } else {
            let (y_res, x_res) = LiquidityPool::get_reserves_size<Y, X, LP>(pool_addr);
            (x_res, y_res)
        }
    }

    /// Get pool curve type (stable/unstable).
    /// * `pool_addr` - pool owner address.
    /// Returns 1 = stable, 2 = uncorrelated (uniswap like).
    public fun get_curve_type<X, Y, LP>(pool_addr: address): u8 {
        if (CoinHelper::is_sorted<X, Y>()) {
            LiquidityPool::get_curve_type<X, Y, LP>(pool_addr)
        } else {
            LiquidityPool::get_curve_type<Y, X, LP>(pool_addr)
        }
    }

    /// Get decimals scales, works only for stable curve.
    /// * `pool_addr` - pool owner address.
    /// Returns `X` and `Y` coins decimals scales.
    public fun get_decimals_scales<X, Y, LP>(pool_addr: address): (u64, u64) {
        if (CoinHelper::is_sorted<X, Y>()) {
            LiquidityPool::get_decimals_scales<X, Y, LP>(pool_addr)
        } else {
            let (y, x) = LiquidityPool::get_decimals_scales<Y, X, LP>(pool_addr);
            (x, y)
        }
    }

    /// Get current cumulative prices in liquidity pool `X`/`Y`.
    /// * `pool_addr` - pool owner address.
    public fun get_cumulative_prices<X, Y, LP>(pool_addr: address): (u128, u128, u64) {
        if (CoinHelper::is_sorted<X, Y>()) {
            LiquidityPool::get_cumulative_prices<X, Y, LP>(pool_addr)
        } else {
            let (y, x, t) = LiquidityPool::get_cumulative_prices<Y, X, LP>(pool_addr);
            (x, y, t)
        }
    }

    // Math.

    /// Calculate amounts needed for adding new liquidity for both `X` and `Y`.
    /// * `pool_addr` - pool owner address.
    /// * `x_desired` - desired value of coins `X`.
    /// * `y_desired` - desired value of coins `Y`.
    /// * `x_min` - minimum of coins X expected.
    /// * `y_min` - minimum of coins Y expected.
    public fun calc_optimal_coin_values<X, Y, LP>(
        pool_addr: address,
        x_desired: u64,
        y_desired: u64,
        x_min: u64,
        y_min: u64
    ): (u64, u64) {
        let (reserves_x, reserves_y) = get_reserves_size<X, Y, LP>(pool_addr);

        if (reserves_x == 0 && reserves_y == 0) {
            return (x_desired, y_desired)
        } else {
            let y_returned = convert_with_current_price(x_desired, reserves_x, reserves_y);
            if (y_returned <= y_desired) {
                assert!(y_returned >= y_min, Errors::invalid_argument(ERR_INSUFFICIENT_Y_AMOUNT));
                return (x_desired, y_returned)
            } else {
                let x_returned = convert_with_current_price(y_desired, reserves_y, reserves_x);
                assert!(x_returned <= x_desired, Errors::invalid_argument(ERR_OVERLIMIT_X));
                assert!(x_returned >= x_min, Errors::invalid_argument(ERR_INSUFFICIENT_X_AMOUNT));
                return (x_returned, y_desired)
            }
        }
    }

    /// Convert `LP` coins to `X` and `Y` coins, useful to calculate amount the user recieve after removing liquidity.
    /// * `pool_addr` - pool owner address.
    /// * `lp_to_burn_val` - amount of `LP` coins to burn.
    /// Returns both `X` and `Y` coins amounts.
    public fun get_reserves_for_lp_coins<X, Y, LP>(
        pool_addr: address,
        lp_to_burn_val: u64
    ): (u64, u64) {
        let (x_reserve, y_reserve) = get_reserves_size<X, Y, LP>(pool_addr);
        let lp_coins_total = supply<LP>();

        let x_to_return_val = Math::mul_div_u128((lp_to_burn_val as u128), (x_reserve as u128), lp_coins_total);
        let y_to_return_val = Math::mul_div_u128((lp_to_burn_val as u128), (y_reserve as u128), lp_coins_total);

        assert!(x_to_return_val > 0 && y_to_return_val > 0, Errors::invalid_argument(ERR_WRONG_AMOUNT));

        (x_to_return_val, y_to_return_val)
    }

    /// Get amount out for `amount_in` of X coins (see generic).
    /// So if Coins::USDC is X and Coins::USDT is Y, it will get amount of USDT you will get after swap `amount_x` USDC.
    /// !Important!: This function can eat a lot of gas if you querying it for stable curve pool, so be aware.
    /// We recommend to do implement such kind of logic offchain.
    /// * `pool_addr` - pool owner address.
    /// * `amount_x` - amount to swap.
    public fun get_amount_out<X, Y, LP>(pool_addr: address, amount_in: u64): u64 {
        let (reserve_x, reserve_y) = get_reserves_size<X, Y, LP>(pool_addr);
        let (scale_x, scale_y) = get_decimals_scales<X, Y, LP>(pool_addr);
        let curve_type = get_curve_type<X, Y, LP>(pool_addr);

        get_coin_out_with_fees(
            amount_in,
            reserve_x,
            reserve_y,
            scale_x,
            scale_y,
            curve_type
        )
    }

    /// Get amount in for `amount_out` of X coins (see generic).
    /// So if Coins::USDT is X and Coins::USDC is Y, you pass how much USDC you want to get and
    /// it returns amount of USDT you have to swap (include fees).
    /// !Important!: This function can eat a lot of gas if you querying it for stable curve pool, so be aware.
    /// We recommend to do implement such kind of logic offchain.
    /// * `pool_addr` - pool owner address.
    /// * `amount_x` - amount to swap.
    public fun get_amount_in<X, Y, LP>(pool_addr: address, amount_out: u64): u64 {
        let (reserve_x, reserve_y) = get_reserves_size<X, Y, LP>(pool_addr);
        let (scale_x, scale_y) = get_decimals_scales<X, Y, LP>(pool_addr);
        let curve_type = get_curve_type<X, Y, LP>(pool_addr);

        get_coin_in_with_fees(
            amount_out,
            reserve_y,
            reserve_x,
            scale_y,
            scale_x,
            curve_type,
        )
    }

    /// Get coin amount out by passing amount in (include fees). Pass all data manually.
    /// * `coin_in` - exactly amount of coins to swap.
    /// * `reserve_in` - reserves of coin we are going to swap.
    /// * `reserve_out` - reserves of coin we are going to get.
    /// * `scale_in` - 10 pow by decimals amount of coin we going to swap.
    /// * `scale_out` - 10 pow by decimals amount of coin we going to get.
    /// * `curve_type` - type of curve (1 = stable, 2 = uncorrelated).
    fun get_coin_out_with_fees(
        coin_in: u64,
        reserve_in: u64,
        reserve_out: u64,
        scale_in: u64,
        scale_out: u64,
        curve_type: u8
    ): u64 {
        let (fee_pct, fee_scale) = LiquidityPool::get_fees_config();
        // 0.997 for 0.3% fee
        let fee_multiplier = fee_scale - fee_pct;

        if (curve_type == STABLE_CURVE) {
            // x_in * 0.997
            let coin_in_val_after_fees = coin_in * fee_multiplier / fee_scale;

            (StableCurve::coin_out(
                (coin_in_val_after_fees as u128),
                scale_in,
                scale_out,
                (reserve_in as u128),
                (reserve_out as u128)
            ) as u64)
        } else if (curve_type == UNSTABLE_CURVE) {
            let coin_in_val_after_fees = coin_in * fee_multiplier;
            // x_reserve size after adding amount_in (scaled to 1000)
            let new_reserve_in = reserve_in * fee_scale + coin_in_val_after_fees;

            // Multiply coin_in by the current exchange rate:
            // current_exchange_rate = reserve_out / reserve_in
            // amount_in_after_fees * current_exchange_rate -> amount_out
            Math::mul_div(coin_in_val_after_fees, // scaled to 1000
                reserve_out,
                new_reserve_in)  // scaled to 1000
        } else {
            abort ERR_INVALID_CURVE
        }
    }

    /// Get coin amount in by amount out. Pass all data manually.
    /// * `coin_out` - exactly amount of coins we want to get.
    /// * `reserve_out` - reserves of coin we are going to get.
    /// * `reserve_in` - reserves of coin we are going to swap.
    /// * `scale_in` - 10 pow by decimals amount of coin we swap.
    /// * `scale_out` - 10 pow by decimals amount of coin we get.
    /// * `curve_type` - type of curve (1 = stable, 2 = uncorrelated).
    ///
    /// This computation is a reverse of get_coin_out formula for uncorrelated assets:
    ///     y = x * 0.997 * ry / (rx + x * 0.997)
    ///
    /// solving it for x returns this formula:
    ///     x = y * rx / ((ry - y) * 0.997) or
    ///     x = y * rx * 1000 / ((ry - y) * 997) which implemented in this function
    ///
    ///  For stable curve math described in `coin_in` func into `../libs/StableCurve.move`.
    fun get_coin_in_with_fees(
        coin_out: u64,
        reserve_out: u64,
        reserve_in: u64,
        scale_out: u64,
        scale_in: u64,
        curve_type: u8
    ): u64 {
        let (fee_pct, fee_scale) = LiquidityPool::get_fees_config();
        // 0.997 for 0.3% fee
        let fee_multiplier = fee_scale - fee_pct;  // 997

        if (curve_type == STABLE_CURVE) {
            // !!!FOR AUDITOR!!!
            // Check it two times.
            (StableCurve::coin_in(
                (coin_out as u128),
                scale_out,
                scale_in,
                (reserve_out as u128),
                (reserve_in as u128),
            ) as u64)
        } else if (curve_type == UNSTABLE_CURVE) {
            // (reserves_out - coin_out) * 0.997
            let new_reserves_out = (reserve_out - coin_out) * fee_multiplier;

            // coin_out * reserve_in * fee_scale / new reserves out
            let coin_in = Math::mul_div(
                coin_out, // y
                reserve_in * fee_scale, // rx * 1000
                new_reserves_out   // (ry - y) * 997
            ) + 1;
            coin_in
        } else {
            abort ERR_INVALID_CURVE
        }
    }

    /// Return amount of liquidity need to for `amount_in`.
    /// * `coin_in` - amount to swap.
    /// * `reserve_in` - reserves of coin to swap.
    /// * `reserve_out` - reserves of coin to get.
    fun convert_with_current_price(coin_in: u64, reserve_in: u64, reserve_out: u64): u64 {
        assert!(coin_in > 0, Errors::invalid_argument(ERR_WRONG_AMOUNT));
        assert!(reserve_in > 0 && reserve_out > 0, Errors::invalid_argument(ERR_WRONG_RESERVE));

        // exchange_price = reserve_out / reserve_in_size
        // amount_returned = coin_in_val * exchange_price
        let res = Math::mul_div(coin_in, reserve_out, reserve_in);
        (res as u64)
    }

    #[test_only]
    public fun convert_with_current_price_for_test(coin_in: u64, reserve_in: u64, reserve_out: u64) : u64 {
        convert_with_current_price(coin_in, reserve_in, reserve_out)
    }

    #[test_only]
    public fun current_price<X, Y, LP>(pool_addr: address): u128 {
        let (x_reserve, y_reserve) = get_reserves_size<X, Y, LP>(pool_addr);
        ((x_reserve / y_reserve) as u128)
    }
}
