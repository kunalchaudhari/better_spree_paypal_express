module Spree
  module Api
    class PaypalController < Spree::Api::BaseController
      before_action :find_order

      def express
        items = @order.line_items.map(&method(:line_item))

        tax_adjustments = @order.all_adjustments.tax.additional
        shipping_adjustments = @order.all_adjustments.shipping

        @order.all_adjustments.eligible.each do |adjustment|
          next if (tax_adjustments + shipping_adjustments).include?(adjustment)
          items << {
            :Name => adjustment.label,
            :Quantity => 1,
            :Amount => {
              :currencyID => @order.currency,
              :value => adjustment.amount
            }
          }
        end

        # Because PayPal doesn't accept $0 items at all.
        # See #10
        # https://cms.paypal.com/uk/cgi-bin/?cmd=_render-content&content_ID=developer/e_howto_api_ECCustomizing
        # "It can be a positive or negative value but not zero."
        items.reject! do |item|
          item[:Amount][:value].zero?
        end

        pp_request = provider.build_set_express_checkout(express_checkout_request_details(@order, items))

        begin
          pp_response = provider.set_express_checkout(pp_request)
          if pp_response.success?
            url = provider.express_checkout_url(pp_response, :useraction => 'commit')
            render json: { success: true, redirect_url: url }, status: 200
          else
            render json: { errors: Spree.t('flash.generic_error', :scope => 'paypal', :reasons => pp_response.errors.map(&:long_message).join(" ")) }, status: 500
          end
        rescue SocketError
          render json: { errors: Spree.t('flash.connection_failed', :scope => 'paypal') }, status: 500
        end
      end

      def confirm
        @order.payments.create!({
          :source => Spree::PaypalExpressCheckout.create({
            :token => params[:paypal_token],
            :payer_id => params[:PayerID]
          }),
          :amount => @order.total,
          :payment_method => payment_method
        })
        respond_with @order
      end

      private
        def find_order
          @order = Spree::Order.find_by(number: params[:number])
          authorize! :read, @order, order_token
        end

        def line_item(item)
          {
              :Name => item.product.name,
              :Number => item.variant.sku,
              :Quantity => item.quantity,
              :Amount => {
                  :currencyID => item.order.currency,
                  :value => item.price
              },
              :ItemCategory => "Physical"
          }
        end

        def express_checkout_request_details order, items
          { :SetExpressCheckoutRequestDetails => {
              :InvoiceID => order.number,
              :BuyerEmail => order.email,
              :ReturnURL => params[:return_url],
              :CancelURL =>  params[:cancel_url],
              :SolutionType => payment_method.preferred_solution.present? ? payment_method.preferred_solution : "Mark",
              :LandingPage => payment_method.preferred_landing_page.present? ? payment_method.preferred_landing_page : "Billing",
              :cppheaderimage => payment_method.preferred_logourl.present? ? payment_method.preferred_logourl : "",
              :NoShipping => 1,
              :PaymentDetails => [payment_details(items)]
          }}
        end

        def payment_method
          Spree::PaymentMethod.find(params[:payment_method_id])
        end

        def provider
          payment_method.provider
        end

        def payment_details items
          # This retrieves the cost of shipping after promotions are applied
          # For example, if shippng costs $10, and is free with a promotion, shipment_sum is now $10
          shipment_sum = @order.shipments.map(&:discounted_cost).sum

          # This calculates the item sum based upon what is in the order total, but not for shipping
          # or tax.  This is the easiest way to determine what the items should cost, as that
          # functionality doesn't currently exist in Spree core
          item_sum = @order.total - shipment_sum - @order.additional_tax_total

          if item_sum.zero?
            # Paypal does not support no items or a zero dollar ItemTotal
            # This results in the order summary being simply "Current purchase"
            {
              :OrderTotal => {
                :currencyID => @order.currency,
                :value => @order.total
              }
            }
          else
            {
              :OrderTotal => {
                :currencyID => @order.currency,
                :value => @order.total
              },
              :ItemTotal => {
                :currencyID => @order.currency,
                :value => item_sum
              },
              :ShippingTotal => {
                :currencyID => @order.currency,
                :value => shipment_sum,
              },
              :TaxTotal => {
                :currencyID => @order.currency,
                :value => @order.additional_tax_total
              },
              :ShipToAddress => address_options,
              :PaymentDetailsItem => items,
              :ShippingMethod => "Shipping Method Name Goes Here",
              :PaymentAction => "Sale"
            }
          end
        end

        def address_options
          return {} unless address_required?

          {
              :Name => @order.bill_address.try(:full_name),
              :Street1 => @order.bill_address.address1,
              :Street2 => @order.bill_address.address2,
              :CityName => @order.bill_address.city,
              :Phone => @order.bill_address.phone,
              :StateOrProvince => @order.bill_address.state_text,
              :Country => @order.bill_address.country.iso,
              :PostalCode => @order.bill_address.zipcode
          }
        end

        def completion_route(order)
          order_path(order, :token => order.guest_token)
        end

        def address_required?
          payment_method.preferred_solution.eql?('Sole')
        end

    end
  end
end
