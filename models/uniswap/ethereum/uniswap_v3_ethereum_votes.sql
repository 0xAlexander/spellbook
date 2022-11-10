{{ config(
    schema = 'uniswap_v3_ethereum',
    alias = 'votes',
    materialized = 'incremental',
    file_format = 'delta',
    incremental_strategy = 'merge',
    unique_key = ['block_time', 'blockchain', 'project', 'version', 'tx_hash'],
    post_hook='{{ expose_spells(\'["ethereum"]\',
                                "project",
                                "uniswap_v3",
                                \'["soispoke"]\') }}'
    )
}}

{% set blockchain = 'ethereum' %}
{% set project = 'uniswap' %}
{% set project_version = 'v3' %}
{% set dao_name = 'DAO: Uniswap' %}
{% set dao_address = '0x408ed6354d4973f66138c91495f2f2fcbd8724c3' %}

WITH cte_sum_votes as 
(SELECT sum(votes/1e18) as sum_votes, 
        proposalId
FROM {{ source('uniswap_v3_ethereum', 'GovernorBravoDelegate_evt_VoteCast') }}
GROUP BY 2)

SELECT 
    '{{blockchain}}' as blockchain,
    '{{project}}' as project,
    '{{project_version}}' as version,
    evt_block_time as block_time,
    evt_tx_hash as tx_hash,
    '{{dao_name}}' as dao_name,
    '{{dao_address}}' as dao_address,
    vc.proposalId as proposal_id,
    votes/1e18 as votes,
    (votes/1e18) * (100) / (sum_votes) as vote_share_percent,
    'UNI' as token_symbol,
    p.contract_address as token_address, 
    votes/1e18 * p.price as votes_value_usd,
    voter as voter_address,
    CASE WHEN support = 0 THEN 'against'
         WHEN support = 1 THEN 'for'
         WHEN support = 2 THEN 'abstain'
         END AS support,
    reason
FROM {{ source('uniswap_v3_ethereum', 'GovernorBravoDelegate_evt_VoteCast') }} vc
LEFT JOIN cte_sum_votes csv ON vc.proposalId = csv.proposalId
LEFT JOIN {{ source('prices', 'usd') }} p ON p.minute = date_trunc('minute', evt_block_time)
    AND p.symbol = 'UNI'
    AND p.blockchain ='ethereum'
{% if is_incremental() %}
WHERE evt_block_time >= date_trunc("day", now() - interval '1 week')
{% endif %}