module Jobs::Cron
  class Portfolio
    Error = Class.new(StandardError)

    class <<self
      def max_liability(portfolio_currency)
        res = ::Portfolio.where(portfolio_currency_id: portfolio_currency).maximum('last_liability_id')
        res.present? ? res : 0
      end

      def portfolio_currencies
        ENV.fetch('PORTFOLIO_CURRENCIES', '').split(',')
      end

      def conversion_market(currency, portfolio_currency)
        market = Market.find_by(base_unit: currency, quote_unit: portfolio_currency)
        raise Error, "There is no market #{currency}#{portfolio_currency}" unless market.present?

        market.id
      end

      def price_at(portfolio_currency, currency, at)
        return 1.0 if portfolio_currency == currency

        market = conversion_market(currency, portfolio_currency)
        nearest_trade = Trade.nearest_trade_from_influx(market, at)
        Rails.logger.info { "Nearest trade on #{market} trade: #{nearest_trade}" }
        raise Error, "There is no trades on market #{market}" unless nearest_trade.present?

        nearest_trade[:price]
      end

      def process_order(portfolio_currency, liability_id, trade, order)
        values = []
        Rails.logger.info { "Process order: #{order.id}" }
        if order.side == 'buy'
          total_credit_fees = trade.amount * trade.order_fee(order)
          total_credit = trade.amount - total_credit_fees
          total_debit = trade.total
        else
          total_credit_fees = trade.total * trade.order_fee(order)
          total_credit = trade.total - total_credit_fees
          total_debit = trade.amount
        end

        if trade.market.quote_unit == portfolio_currency
          income_currency_id = order.income_currency.id
          order.side == 'buy' ? total_credit_value = total_credit * trade.price : total_credit_value = total_credit
          values << portfolios_values(order.member_id, portfolio_currency, income_currency_id, total_credit, total_credit_fees, total_credit_value, liability_id, 0, 0, 0)

          outcome_currency_id = order.outcome_currency.id
          order.side == 'buy' ? total_debit_value = total_debit : total_debit_value = total_debit * trade.price
          values << portfolios_values(order.member_id, portfolio_currency, outcome_currency_id, 0, 0, 0, liability_id, total_debit, total_debit_value, 0)
        else
          income_currency_id = order.income_currency.id
          total_credit_value = (total_credit) * price_at(portfolio_currency, income_currency_id, trade.created_at)
          values << portfolios_values(order.member_id, portfolio_currency, income_currency_id, total_credit, total_credit_fees, total_credit_value, liability_id, 0, 0, 0)

          outcome_currency_id = order.outcome_currency.id
          total_debit_value = (total_debit) * price_at(portfolio_currency, outcome_currency_id, trade.created_at)
          values << portfolios_values(order.member_id, portfolio_currency, outcome_currency_id, 0, 0, 0, liability_id, total_debit, total_debit_value, 0)
        end

        values
      end

      def process_deposit(portfolio_currency, liability_id, deposit)
        Rails.logger.info { "Process deposit: #{deposit.id}" }
        total_credit = deposit.amount
        total_credit_fees = deposit.fee
        total_credit_value = total_credit * price_at(portfolio_currency, deposit.currency_id, deposit.created_at)
        portfolios_values(deposit.member_id, portfolio_currency, deposit.currency_id, total_credit, total_credit_fees, total_credit_value, liability_id, 0, 0, 0)
      end

      def process_withdraw(portfolio_currency, liability_id, withdraw)
        Rails.logger.info { "Process withdraw: #{withdraw.id}" }
        total_debit = withdraw.amount
        total_debit_fees = withdraw.fee
        total_debit_value = (total_debit + total_debit_fees) * price_at(portfolio_currency, withdraw.currency_id, withdraw.created_at)

        portfolios_values(withdraw.member_id, portfolio_currency, withdraw.currency_id, 0, 0, 0, liability_id, total_debit, total_debit_value, total_debit_fees)
      end

      def process
        l_count = 0
        portfolio_currencies.each do |portfolio_currency|
          begin
            l_count += process_currency(portfolio_currency)
          rescue StandardError => e
            Rails.logger.error("Failed to process currency #{portfolio_currency}: #{e}")
          end
        end

        sleep 2 if l_count == 0
      end

      def process_currency(portfolio_currency)
        byebug
        l_count = 0
        values = []
        liability_pointer = max_liability(portfolio_currency)
        # We use MIN function here instead of ANY_VALUE to be compatible with more MySQL versions
        ActiveRecord::Base.connection
          .select_all("SELECT MAX(id) id, MIN(reference_type) reference_type, MIN(reference_id) reference_id " \
                      "FROM liabilities WHERE id > #{liability_pointer} " \
                      "AND ((reference_type IN ('Trade','Deposit','Adjustment') AND code IN (201,202)) " \
                      "OR (reference_type IN ('Withdraw') AND code IN (211,212))) " \
                      "GROUP BY reference_id ORDER BY MAX(id) ASC LIMIT 10000")
          .each do |liability|
            l_count += 1
            Rails.logger.info { "Process liability: #{liability['id']}" }

            case liability['reference_type']
              when 'Deposit'
                deposit = Deposit.find(liability['reference_id'])
                values << process_deposit(portfolio_currency, liability['id'], deposit)
              when 'Trade'
                trade = Trade.find(liability['reference_id'])
                values += process_order(portfolio_currency, liability['id'], trade, trade.maker_order)
                values += process_order(portfolio_currency, liability['id'], trade, trade.taker_order)
              when 'Withdraw'
                withdraw = Withdraw.find(liability['reference_id'])
                values << process_withdraw(portfolio_currency, liability['id'], withdraw)
            end
        end

        transfers = {}
        ActiveRecord::Base.connection
          .select_all("SELECT * FROM liabilities WHERE id > #{liability_pointer} " \
                      "AND ((reference_type = 'Transfer' AND code IN (201,202,211,212)) " \
                      "ORDER BY id ASC LIMIT 10000")
          .each do |l|
            l_count += 1
            ref = l['reference_id']
            cid = l['currency_id']
            mid = l['memeber_id']
            transfers[ref] ||= {}
            transfers[ref][cid] ||= {
              type: nil,
              liabilities: []
            }
            # We ignore lock liabilities (destination account type lock)
            # Still the source account can be lock or main
            if l['credit'].positive?
              if [211, 212].include?(l['code'])
                transfers[ref][cid][:type] = :lock
              elsif [201, 202].include?(l['code'])
                transfers[ref][cid][:type] ||= :main
              end
            end
            transfers[ref][cid][:liabilities] << l
        end

        transfers.each do |ref, transfer|
          case transfer.size # number of currencies in the transfer
          when 1
            # Probably a lock transfer, ignoring

          when 2
            # We have 2 currencies exchanges, so we can integrate those numbers in acquisition cost calculation
            store = Hash.new do |member_store, mid|
              member_store[mid] = Hash.new do |h, k|
                h[k] = {
                  total_credit_fees: 0,
                  total_credit: 0,
                  total_debit: 0,
                  total_amount: 0,
                  liability_id: 0
                }
              end
            end
            transfer.each do |cid, infos|
              unless infos[:type] == :main
                logger.error 'Account destination type not identified' unless infos[:type]
                logger.error 'Transfer flags locked with several currencies' if infos[:type] == :lock
                next
              end

              Operations::Revenue.where(reference_type: 'Transfer', reference_id: ref, currency_id: cid).each do |fee|
                i = infos[:liabilities].find_index{|l| l.debit == fee.credit && l.credit == fee.debit }
                if i
                  l = infos[:liabilities].delete_at(i)
                  store[l.member_id][cid][:total_credit_fees] += fee.credit
                end
              end

              infos[:liabilities].each do |l|
                store[l.member_id] ||= {}
                store[l.member_id][cid]
                store[l.member_id][cid][:total_credit] += l.credit
                store[l.member_id][cid][:total_debit] += l.debit
                store[l.member_id][cid][:total_amount] += (l.credit + l.debit)
                store[l.member_id][cid][:liability_id] = l.id if store[l.member_id][cid][:liability_id] < l.id
              end
            end

            # store = {
            #   1 => {
            #     "usd" => {
            #       total_credit: 100,
            #       total_debit: 0
            #     },
            #     "btc" => {
            #       total_credit: 0,
            #       total_debit: 0.09
            #     }
            #   },
            #   2 => {
            #     "usd" => {
            #       total_credit: 0,
            #       total_debit: 89,
            #       total_credit_fees: 1
            #     },
            #     "btc" => {
            #       total_credit: 0.09,
            #       total_debit: 0
            #     }
            #   }
            # }

            def price_of_transfer(a_total, b_total)
              b_total / a_total
            end

            store.each do |member_id, stats|
              a, b = stats.keys

              if a == portfolio_currency
                b, a = stats.keys
              elsif b != portfolio_currency
                raise "Need direct conversion for transfers"
              end

              price = price_of_transfer(stats[a][:total_amount], stats[b][:total_amount])

              a_total_credit_value = stats[a][:total_credit] * price
              b_total_credit_value = stats[b][:total_credit]

              a_total_debit_value = stats[a][:total_debit] * price
              b_total_debit_value = stats[b][:total_debit]

              values << portfolios_values(member_id, portfolio_currency, a, stats[a][:total_credit], stats[a][:total_credit_fees], a_total_credit_value, stats[a][:liability_id], stats[a][:total_debit], a_total_debit_value, 0)
              values << portfolios_values(member_id, portfolio_currency, b, stats[b][:total_credit], stats[b][:total_credit_fees], b_total_credit_value, stats[b][:liability_id], stats[b][:total_debit], b_total_debit_value, 0)
            end

          else
            raise "Transfers with more than 2 currencies brakes pnl calculation"
          end
          l_count
        end

        create_or_update_portfolio(values) if values.present?
      end

      def portfolios_values(member_id, portfolio_currency_id, currency_id, total_credit, total_credit_fees, total_credit_value, liability_id, total_debit, total_debit_value, total_debit_fees)
        "(#{member_id},'#{portfolio_currency_id}','#{currency_id}',#{total_credit},#{total_credit_fees},#{total_credit_value},#{liability_id},#{total_debit},#{total_debit_value},#{total_debit_fees})"
      end

      def create_or_update_portfolio(values)
        sql = "INSERT INTO portfolios (member_id, portfolio_currency_id, currency_id, total_credit, total_credit_fees, total_credit_value, last_liability_id, total_debit, total_debit_value, total_debit_fees) " \
              "VALUES #{values.join(',')} " \
              "ON DUPLICATE KEY UPDATE " \
              "total_credit = total_credit + VALUES(total_credit), " \
              "total_credit_fees = total_credit_fees + VALUES(total_credit_fees), " \
              "total_debit_fees = total_debit_fees + VALUES(total_debit_fees), " \
              "total_credit_value = total_credit_value + VALUES(total_credit_value), " \
              "total_debit_value = total_debit_value + VALUES(total_debit_value), " \
              "total_debit = total_debit + VALUES(total_debit), " \
              "updated_at = NOW(), " \
              "last_liability_id = VALUES(last_liability_id)"

        ActiveRecord::Base.connection.exec_query(sql)
      end
    end
  end
end