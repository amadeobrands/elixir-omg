defmodule OmiseGO.API.BlockQueue do
  @moduledoc """
  Responsible for keeping a queue of blocks lined up nicely for submission to Eth.
  In particular responsible for picking up, where it's left off (crashed) gracefully.

  Relies on RootChain contract having reorg protection ('decimals for deposits' part).
  Relies on RootChain contract's 'authority' account not being used to send any other tx.

  It reacts to extarnal requests of changing gas price and resubmits submitBlock txes not being mined
  For changing the gas price it needs external singlas (e.g. from a price oracle)
  """

  alias OmiseGO.API.BlockQueue.Core, as: Core
  alias OmiseGO.Eth.BlockSubmission

  require Logger

  @type eth_height() :: non_neg_integer()
  @type hash() :: BlockSubmission.hash()
  @type plasma_block_num() :: BlockSubmission.plasma_block_num()
  # child chain block number, as assigned by plasma contract
  @type encoded_signed_tx() :: binary()

  ### Client

  def enqueue_block(block_hash) do
    GenServer.call(__MODULE__.Server, {:enqueue_block, block_hash})
  end

  # CONFIG constant functions
  # TODO rethink. Possibly fetch from the contract? (would complicate things, but we must unconditionally match that)
  def child_block_interval, do: Application.get_env(:omisego_eth, :child_block_interval)

  defmodule Server do
    @moduledoc """
    Stores core's state, handles timing of calls to root chain.
    Is driven by block height and mined tx data delivered by local geth node and new blocks
    formed by server. It may resubmit tx multiple times, until it is mined.
    """

    use GenServer

    alias OmiseGO.API.BlockQueue
    alias OmiseGO.Eth

    def start_link(_args) do
      GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
    end

    def init(:ok) do
      try do
        with :ok <- Eth.node_ready(),
             :ok <- Eth.contract_ready(),
             {:ok, parent_height} <- Eth.get_ethereum_height(),
             {:ok, mined_num} <- Eth.get_mined_child_block(),
             {:ok, parent_start} <- Eth.get_root_deployment_height(),
             {:ok, stored_child_top_num} <- OmiseGO.DB.child_top_block_number(),
             _ =
               Logger.info(fn ->
                 "Starting BlockQueue at parent_height: #{parent_height}, mined_child_block: #{mined_num}, " <>
                   "parent_start: #{parent_start}, stored_child_top_block: #{stored_child_top_num}"
               end),
             range <- Core.child_block_nums_to_init_with(stored_child_top_num),
             # TODO: taking all stored hashes now. While still being feasible DB-wise ("just" many hashes)
             #       it might be prohibitive, if we create BlockSubmissions out of the unfiltered batch
             #       (see enqueue_existing_blocks). Probably we want to set a hard cutoff and do
             #       OmiseGO.DB.block_hashes(stored_child_top_num - cutoff..stored_child_top_num)
             #       Leaving a chore to handle that in the future: OMG-83
             {:ok, known_hashes} <- OmiseGO.DB.block_hashes(range),
             {:ok, {top_mined_hash, _}} = Eth.get_child_chain(mined_num) do
          _ = Logger.info(fn -> "Starting BlockQueue, top_mined_hash: #{inspect(top_mined_hash)}" end)

          {:ok, state} =
            Core.new(
              mined_child_block_num: mined_num,
              known_hashes: known_hashes,
              top_mined_hash: top_mined_hash,
              parent_height: parent_height,
              child_block_interval: BlockQueue.child_block_interval(),
              chain_start_parent_height: parent_start,
              submit_period: Application.get_env(:omisego_api, :child_block_submit_period),
              finality_threshold: Application.get_env(:omisego_api, :ethereum_event_block_finality_margin)
            )

          interval = Application.get_env(:omisego_api, :ethereum_event_check_height_interval_ms)
          {:ok, _} = :timer.send_interval(interval, self(), :check_mined_child_head)
          {:ok, _} = :timer.send_interval(interval, self(), :check_ethereum_height)

          _ = Logger.info(fn -> "Started BlockQueue" end)
          {:ok, state}
        end
      catch
        error -> {:stop, {:unable_to_init_block_queue, error}}
      end
    end

    def handle_info(:check_mined_child_head, state) do
      {:ok, mined_num} = Eth.get_mined_child_block()
      state1 = Core.set_mined(state, mined_num)
      submit_blocks(state1)
      {:noreply, state1}
    end

    def handle_info(:check_ethereum_height, state) do
      with {:ok, height} <- Eth.get_ethereum_height(),
           {:do_form_block, state1, block_num, next_block_num} <- Core.set_ethereum_height(state, height),
           {:ok, block_hash} <- OmiseGO.API.State.form_block(block_num, next_block_num) do
        state2 = Core.enqueue_block(state1, block_hash)
        submit_blocks(state2)
        {:noreply, state2}
      else
        {:dont_form_block, state1} -> {:noreply, state1}
        other -> other
      end
    end

    # private (server)

    @spec submit_blocks(Core.t()) :: :ok
    defp submit_blocks(state) do
      state
      |> Core.get_blocks_to_submit()
      |> Enum.each(&submit/1)
    end

    defp submit(submission) do
      _ = Logger.debug(fn -> "Submitting: #{inspect(submission)}" end)

      case OmiseGO.Eth.submit_block(submission) do
        {:ok, txhash} ->
          _ = Logger.info(fn -> "Submitted #{inspect(submission)} at: #{inspect(txhash)}" end)
          :ok

        {:error, %{"code" => -32_000, "message" => "known transaction" <> _}} ->
          _ = Logger.debug(fn -> "Submission is known transaction - ignored" end)
          :ok

        {:error, %{"code" => -32_000, "message" => "replacement transaction underpriced"}} ->
          _ = Logger.debug(fn -> "Submission is known, but with higher price - ignored" end)
          :ok
      end
    end
  end
end
