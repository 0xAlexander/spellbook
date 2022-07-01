 {{ config(alias='transactions') }}

WITH looks_rare AS (
        SELECT 
        ask.evt_block_time AS block_time,
        ask.tokenId::string AS token_id,
        ask.amount AS number_of_items,
        taker AS seller,
        maker AS buyer,
        price AS price,
        roy.amount AS fees,
        roy.royaltyRecipient AS fee_receive_address,
        roy.currency AS fee_currency_symbol,
        CASE -- REPLACE `ETH` WITH `WETH` for ERC20 lookup later
            WHEN ask.currency = '0x0000000000000000000000000000000000000000' THEN '0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2'
            ELSE ask.currency
        END AS currency_contract,
        ask.currency AS original_currency_address,
        ask.collection AS nft_contract_address,
        ask.contract_address AS contract_address,
        ask.evt_tx_hash AS tx_hash,
        ask.evt_block_number AS block_number,
        ask.evt_index AS evt_index,
        CASE -- CATEGORIZE Collection Wide Offers Accepted 
            WHEN strategy = '0x86f909f70813cdb1bc733f4d97dc6b03b8e7e8f3' THEN 'Collection Offer Accepted'
            ELSE 'Offer Accepted' 
            END AS category    
    FROM {{ source('looksrare_ethereum','looksrareexchange_evt_takerask') }} ask
    LEFT JOIN {{ source('looksrare_ethereum','looksrareexchange_evt_royaltypayment') }} roy ON roy.evt_tx_hash = ask.evt_tx_hash
                            UNION ALL
    SELECT 
        bid.evt_block_time AS block_time,
        bid.tokenId::string AS token_id,
        bid.amount AS number_of_items,
        maker AS seller,
        taker AS buyer,
        price AS price,
        roy.amount AS fees,
        roy.royaltyRecipient AS fee_receive_address,
        roy.currency AS fee_currency_symbol,
       CASE -- REPLACE `ETH` WITH `WETH` for ERC20 lookup later
            WHEN bid.currency = '0x0000000000000000000000000000000000000000' THEN '0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2'
            ELSE bid.currency
        END AS currency_contract,
        bid.currency AS original_currency_address,
        bid.collection AS nft_contract_address,
        bid.contract_address AS contract_address,
        bid.evt_tx_hash AS tx_hash,
        bid.evt_block_number AS block_number,
        bid.evt_index AS evt_index,
        'Buy' as category
    FROM {{ source('looksrare_ethereum','looksrareexchange_evt_takerbid') }} bid
    LEFT JOIN {{ source('looksrare_ethereum','looksrareexchange_evt_royaltypayment') }} roy ON roy.evt_tx_hash = bid.evt_tx_hash
    ),

-- Get ERC721 AND ERC1155 transfer data for every trade TRANSACTION
erc_transfers as
(SELECT evt_tx_hash,
        id::string as token_id_erc,
        cardinality(collect_list(value)) as count_erc,
        value as value_unique,
        CASE WHEN erc1155.from = '0x0000000000000000000000000000000000000000' THEN 'Mint'
        WHEN erc1155.to = '0x0000000000000000000000000000000000000000' 
        OR erc1155.to = '0x000000000000000000000000000000000000dead' THEN 'Burn' 
        ELSE 'Trade' END AS evt_type,
        evt_index
        FROM {{ source('erc1155_ethereum','evt_transfersingle') }} erc1155
        GROUP BY evt_tx_hash,value,id,evt_index, erc1155.from, erc1155.to
            UNION ALL
SELECT evt_tx_hash,
        tokenId::string as token_id_erc,
        COUNT(tokenId) as count_erc,
        NULL as value_unique,
        CASE WHEN erc721.from = '0x0000000000000000000000000000000000000000' THEN 'Mint'
        WHEN erc721.to = '0x0000000000000000000000000000000000000000' 
        OR erc721.to = '0x000000000000000000000000000000000000dead' THEN 'Burn' 
        ELSE 'Trade' END AS evt_type,
        evt_index
        FROM {{ source('erc721_ethereum','evt_transfer') }} erc721
        GROUP BY evt_tx_hash,tokenId,evt_index, erc721.from, erc721.to)

   SELECT
        'ethereum' as blockchain,
        'looksrare' as project,
        'v1' as version,
        block_time,
        token_id,
        tokens.name END AS collection,
        price / power(10,erc20.decimals) * p.price END AS usd_amount,
        tokens.standard END AS erc_standard,
        CASE WHEN erc_transfers.value_unique >= 1 THEN 'erc1155'
            WHEN erc_transfers.value_unique is null THEN 'erc721'
            ELSE wa.token_standard END AS token_standard,
        CASE 
            WHEN agg.name is NULL AND erc_transfers.value_unique = 1 OR erc_transfers.count_erc = 1 THEN 'Single Item Trade'
            WHEN agg.name is NULL AND erc_transfers.value_unique > 1 OR erc_transfers.count_erc > 1 THEN 'Bundle Trade'
        ELSE wa.trade_type END AS trade_type,
        -- Count number of items traded for different trade types and erc standards
        CASE WHEN agg.name is NULL AND erc_transfers.value_unique > 1 THEN erc_transfers.value_unique
            WHEN agg.name is NULL AND erc_transfers.value_unique is NULL AND erc_transfers.count_erc > 1 THEN erc_transfers.count_erc
            WHEN wa.trade_type = 'Single Item Trade' THEN cast(1 as bigint)
            WHEN wa.token_standard = 'erc1155' THEN erc_transfers.value_unique
            WHEN wa.token_standard = 'erc721' THEN erc_transfers.count_erc
            ELSE (SELECT
                    count(1)::bigint cnt
                FROM {{ source('erc721_ethereum','evt_transfer') }} erc721
                WHERE erc721.evt_tx_hash = wa.call_tx_hash
                ) +    
                (SELECT
                    count(1)::bigint cnt
                FROM {{ source('erc1155_ethereum','evt_transfersingle') }} erc1155
                WHERE erc1155.evt_tx_hash = wa.call_tx_hash
                ) END AS number_of_items,
        category as trade_category,
        evt_type,
        seller,
        buyer,
        price / power(10,erc20.decimals) AS amount_original,
        price AS amount_raw,
        CASE WHEN original_currency_address = '0x0000000000000000000000000000000000000000' THEN 'ETH' ELSE erc20.symbol END AS currency_symbol,
        currency_contract_original AS currency_contract_original,
        contract_address AS nft_contract_address,
        CASE WHEN looks_rare.original_currency_address = '0x0000000000000000000000000000000000000000' THEN 'ETH' ELSE erc20.symbol END AS currency_symbol,
        original_currency_address AS original_currency_contract,
        currency_contract,
        COALESCE(erc.contract_address, nft_contract_address) AS nft_contract_address,
        looksrare.contract_address AS project_contract_address,
        agg.name AS aggregator_name,
        agg.name AS aggregator_address,
        tx_hash,
        block_number,
        tx.from AS tx_from,
        tx.to AS tx_to,
        fees as fee_amount_raw,
        fees / power(10,erc20.decimals) as fee_amount,
        fees * p.price/ power(10,erc20.decimals) as fee_amount_usd,
        fee_receive_address,
        fee_currency_symbol,
        tx_hash || '-' ||  token_id || '-' ||  seller || '-' || erc.evt_index as unique_trade_id
    FROM looks_rare
    INNER JOIN {{ source('ethereum','transactions') }} tx ON tx_hash = tx.hash
    LEFT JOIN erc_transfers erc ON erc.evt_tx_hash = tx_hash and erc.token_id_erc = looks_rare.token_id
    LEFT JOIN {{ ref('tokens_ethereum_nft') }} tokens ON tokens.contract_address =  nft_contract_address
    LEFT JOIN  {{ ref('nft_ethereum_aggregators') }} agg ON agg.address = tx.to
    LEFT JOIN {{ source('prices', 'usd') }} p ON p.minute = date_trunc('minute', block_time)
        AND p.contract_address = currency_contract
        AND p.blockchain ='ethereum'
    LEFT JOIN {{ ref('tokens_ethereum_erc20') }} erc20 ON erc20.contract_address = currency_token