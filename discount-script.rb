class Campaign
  def initialize(condition, *qualifiers)
    @condition = condition == :default ? :all? : (condition.to_s + '?').to_sym
    @qualifiers = PostCartAmountQualifier ? [] : [] rescue qualifiers.compact
    @line_item_selector = qualifiers.last unless @line_item_selector
    qualifiers.compact.each do |qualifier|
      is_multi_select = qualifier.instance_variable_get(:@conditions).is_a?(Array)
      if is_multi_select
        qualifier.instance_variable_get(:@conditions).each do |nested_q| 
          @post_amount_qualifier = nested_q if nested_q.is_a?(PostCartAmountQualifier)
          @qualifiers << qualifier
        end
      else
        @post_amount_qualifier = qualifier if qualifier.is_a?(PostCartAmountQualifier)
        @qualifiers << qualifier
      end
    end if @qualifiers.empty?
  end
  
  def qualifies?(cart)
    return true if @qualifiers.empty?
    @unmodified_line_items = cart.line_items.map do |item|
      new_item = item.dup
      new_item.instance_variables.each do |var|
        val = item.instance_variable_get(var)
        new_item.instance_variable_set(var, val.dup) if val.respond_to?(:dup)
      end
      new_item  
    end if @post_amount_qualifier
    @qualifiers.send(@condition) do |qualifier|
      is_selector = false
      if qualifier.is_a?(Selector) || qualifier.instance_variable_get(:@conditions).any? { |q| q.is_a?(Selector) }
        is_selector = true
      end rescue nil
      if is_selector
        raise "Missing line item match type" if @li_match_type.nil?
        cart.line_items.send(@li_match_type) { |item| qualifier.match?(item) }
      else
        qualifier.match?(cart, @line_item_selector)
      end
    end
  end

  def revert_changes(cart)
    cart.instance_variable_set(:@line_items, @unmodified_line_items)
  end
end

class BundleDiscount < Campaign
  def initialize(condition, customer_qualifier, cart_qualifier, discount, full_bundles_only, bundle_products)
    super(condition, customer_qualifier, cart_qualifier)
    @bundle_products = bundle_products
    @discount = discount
    @full_bundles_only = full_bundles_only
    @split_items = []
    @bundle_items = []
  end
  
  def check_bundles(cart)
      bundled_items = @bundle_products.map do |bitem|
        quantity_required = bitem[:quantity].to_i
        qualifiers = bitem[:qualifiers]
        type = bitem[:type].to_sym
        case type
          when :ptype
            items = cart.line_items.select { |item| qualifiers.include?(item.variant.product.product_type) }
          when :ptag
            items = cart.line_items.select { |item| (qualifiers & item.variant.product.tags).length > 0 }
          when :pid
            qualifiers.map!(&:to_i)
            items = cart.line_items.select { |item| qualifiers.include?(item.variant.product.id) }
          when :vid
            qualifiers.map!(&:to_i)
            items = cart.line_items.select { |item| qualifiers.include?(item.variant.id) }
        end
        
        total_quantity = items.reduce(0) { |total, item| total + item.quantity }
        {
          has_all: total_quantity >= quantity_required,
          total_quantity: total_quantity,
          quantity_required: quantity_required,
          total_possible: (total_quantity / quantity_required).to_i,
          items: items
        }
      end
      
      max_bundle_count = bundled_items.map{ |bundle| bundle[:total_possible] }.min if @full_bundles_only
      if bundled_items.all? { |item| item[:has_all] }
        if @full_bundles_only
          bundled_items.each do |bundle|
            bundle_quantity = bundle[:quantity_required] * max_bundle_count
            split_out_extra_quantity(cart, bundle[:items], bundle[:total_quantity], bundle_quantity)
          end
        else
          bundled_items.each do |bundle|
            bundle[:items].each do |item| 
              @bundle_items << item 
              cart.line_items.delete(item)
            end
          end
        end
        return true
      end
      false
  end
  
  def split_out_extra_quantity(cart, items, total_quantity, quantity_required)
    items_to_split = quantity_required
    items.each do |item|
      break if items_to_split == 0
      if item.quantity > items_to_split
        @bundle_items << item.split({take: items_to_split})
        @split_items << item
        items_to_split = 0
      else
        @bundle_items << item
        split_quantity = item.quantity
        items_to_split -= split_quantity
      end
      cart.line_items.delete(item)
    end
    cart.line_items.concat(@split_items)
    @split_items.clear
  end
  
  def run(cart)
    raise "Campaign requires a discount" unless @discount
    return unless qualifies?(cart)
    
    if check_bundles(cart)
      @bundle_items.each { |item| @discount.apply(item) }
    end
    @bundle_items.reverse.each { |item| cart.line_items.prepend(item) }
  end
end

class PercentageDiscount
  def initialize(percent, message)
    @discount = (100 - percent) / 100.0
    @message = message
  end

  def apply(line_item)
    line_item.change_line_price(line_item.line_price * @discount, message: @message)
  end
end

CAMPAIGNS = [
  BundleDiscount.new(
    :all,
    nil,
    nil,
    PercentageDiscount.new(
      10,
      "Save 10% with our Sets"
    ),
    true,
    [{:type => "vid", :qualifiers => ["12245770109044"], :quantity => "1"},	{:type => "vid", :qualifiers => ["12245773123700"], :quantity => "1"},	{:type => "vid", :qualifiers => ["12245775941748"], :quantity => "1"},	{:type => "vid", :qualifiers => ["18844374270048"], :quantity => "1"}]
  ),
].freeze

CAMPAIGNS.each do |campaign|
  campaign.run(Input.cart)
end

Output.cart = Input.cart
