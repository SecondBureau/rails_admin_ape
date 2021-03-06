module RailsAdmin

  class MainController < RailsAdmin::ApplicationController
    include ActionView::Helpers::TextHelper

    layout "rails_admin/application"

    before_filter :get_model, :except => [:dashboard]
    before_filter :get_object, :only => [:show, :edit, :update, :delete, :destroy]
    before_filter :get_attributes, :only => [:create, :update]
    before_filter :check_for_cancel, :only => [:create, :update, :destroy, :export, :bulk_destroy]

    def dashboard
      @authorization_adapter.authorize(:dashboard) if @authorization_adapter
      @page_name = t("admin.dashboard.pagename")
      @page_type = "dashboard"

      @history = AbstractHistory.history_latest_summaries
      @month = DateTime.now.month
      @year = DateTime.now.year
      @history= AbstractHistory.history_for_month(@month, @year)

      @abstract_models = RailsAdmin::Config.visible_models.map(&:abstract_model)

      @most_recent_changes = {}
      @count = {}
      @max = 0
      @abstract_models.each do |t|
        scope = @authorization_adapter && @authorization_adapter.query(:index, t)
        current_count = t.count({}, scope)
        @max = current_count > @max ? current_count : @max
        @count[t.pretty_name] = current_count
        @most_recent_changes[t.pretty_name] = t.model.order("updated_at desc").first.try(:updated_at) rescue nil
      end
      render :dashboard
    end

    def index
      if @model_config.index == :show
        redirect_to :action => "show", :id => 1
        return
      end
      @authorization_adapter.authorize(:index, @abstract_model) if @authorization_adapter

      @page_type = @abstract_model.pretty_name.downcase
      @page_name = t("admin.index.select", :name => @model_config.label.downcase)

      @objects = list_entries
      @schema ||= { :only => @model_config.list.visible_fields.map {|f| f.name } }
      respond_to do |format|
        format.html do
          begin
            render "rails_admin/#{params[:model_name]}/index", :layout => !request.xhr?
          rescue
            render :layout => !request.xhr?
          end
        end
        format.json do
          output = if params[:compact]
            @objects.map{ |o| { :id => o.id, :label => o.send(@model_config.object_label_method) } }
          else
            @objects.to_json(@schema)
          end
          if params[:send_data]
            send_data output, :filename => "#{params[:model_name]} #{DateTime.now.strftime("%Y-%m-%d %H:%M:%S")}.json"
          else
            render :json => output
          end
        end
        format.xml do
          output = @objects.to_xml(@schema)
          if params[:send_data]
            send_data output, :filename => "#{params[:model_name]} #{DateTime.now.strftime("%Y-%m-%d %H:%M:%S")}.xml"
          else
            render :xml => output
          end
        end
        format.csv do
          header, encoding, output = CSVConverter.new(@objects, @schema).to_csv(params[:csv_options])
          if params[:send_data]
            send_data output,
              :type => "text/csv; charset=#{encoding}; #{"header=present" if header}",
              :disposition => "attachment; filename=#{params[:model_name]} #{DateTime.now.strftime("%Y-%m-%d %H:%M:%S")}.csv"
          else
            render :text => output
          end
        end
      end
    end

    def new
      @object = @abstract_model.new
      if @authorization_adapter
        @authorization_adapter.attributes_for(:new, @abstract_model).each do |name, value|
          @object.send("#{name}=", value)
        end
        @authorization_adapter.authorize(:new, @abstract_model, @object)
      end
      if object_params = params[@abstract_model.to_param]
        @object.set_attributes(@object.attributes.merge(object_params), _attr_accessible_role)
      end
      @page_name = t("admin.actions.create").capitalize + " " + @model_config.label.downcase
      @page_type = @abstract_model.pretty_name.downcase
      respond_to do |format|
        format.html do
          begin
            render "rails_admin/#{params[:model_name]}/new"
          rescue
            render
          end
        end
        format.js   { render :layout => false }
      end
    end

    def create
      @modified_assoc = []
      @object = @abstract_model.new
      @model_config.create.fields.each {|f| f.parse_input(@attributes) if f.respond_to?(:parse_input) }
      if @authorization_adapter
        @authorization_adapter.attributes_for(:create, @abstract_model).each do |name, value|
          @object.send("#{name}=", value)
        end
        @authorization_adapter.authorize(:create, @abstract_model, @object)
      end
      @object.set_attributes(@attributes, _attr_accessible_role)
      @page_name = t("admin.actions.create").capitalize + " " + @model_config.label.downcase
      @page_type = @abstract_model.pretty_name.downcase

      if @object.save
        AbstractHistory.create_history_item("Created #{@model_config.with(:object => @object).object_label}", @object, @abstract_model, _current_user)
        respond_to do |format|
          format.html do
            redirect_to_on_success
          end
          format.js do
            render :json => {
              :id => @object.id,
              :label => @model_config.with(:object => @object).object_label,
            }
          end
        end
      else
        handle_save_error
      end
    end

    def show
      @authorization_adapter.authorize(:show, @abstract_model, @object) if @authorization_adapter
      if @model_config.index == :show
        @page_name = t("admin.show.page_name", :name => "#{@model_config.label.downcase}")
      else
        @page_name = t("admin.show.page_name", :name => "#{@model_config.label.downcase} '#{@object.send(@model_config.object_label_method)}'")
      end
      @page_type = @abstract_model.pretty_name.downcase
      respond_to do |format|
        format.html do
          begin
            render "rails_admin/#{params[:model_name]}/show"
          rescue
            render
          end
        end
      end
    end

    def edit
      @authorization_adapter.authorize(:edit, @abstract_model, @object) if @authorization_adapter
      if @model_config.index == :show
        @page_name = "#{t("admin.actions.update").capitalize} #{@model_config.label.downcase}"
      else
        @page_name = "#{t("admin.actions.update").capitalize} #{@model_config.label.downcase} '#{@object.send(@model_config.object_label_method)}'"
      end
      @page_type = @abstract_model.pretty_name.downcase
      respond_to do |format|
        format.html do
          begin
            render "rails_admin/#{params[:model_name]}/edit"
          rescue
            render
          end
        end
        format.js   { render :layout => false }
      end
    end

    def update
      @authorization_adapter.authorize(:update, @abstract_model, @object) if @authorization_adapter

      @cached_assocations_hash = associations_hash
      @modified_assoc = []

      @page_name = "#{t("admin.actions.update").capitalize} #{@model_config.label.downcase} '#{@object.send(@model_config.object_label_method)}'"
      @page_type = @abstract_model.pretty_name.downcase

      @old_object = @object.dup

      @model_config.update.fields.map {|f| f.parse_input(@attributes) if f.respond_to?(:parse_input) }

      @object.set_attributes(@attributes, _attr_accessible_role)

      if @object.save
        AbstractHistory.create_update_history @abstract_model, @object, @cached_assocations_hash, associations_hash, @modified_assoc, @old_object, _current_user
        respond_to do |format|
          format.html do
            redirect_to_on_success
          end
          format.js do
            render :json => {
              :id => @object.id,
              :label => @model_config.with(:object => @object).object_label,
            }
          end
        end
      else
        handle_save_error :edit
      end
    end

    def delete
      @authorization_adapter.authorize(:delete, @abstract_model, @object) if @authorization_adapter
      @page_name = "#{t("admin.actions.delete").capitalize} #{@model_config.label.downcase} '#{@object.send(@model_config.object_label_method)}'"
      @page_type = @abstract_model.pretty_name.downcase
      respond_to do |format|
        format.html
        format.js   { render :layout => false }
      end
    end

    def destroy
      @authorization_adapter.authorize(:destroy, @abstract_model, @object) if @authorization_adapter

      if @object.destroy
        AbstractHistory.create_history_item("Destroyed #{@model_config.with(:object => @object).object_label}", @object, @abstract_model, _current_user)
        flash[:success] = t("admin.flash.successful", :name => @model_config.label, :action => t("admin.actions.deleted"))
      else
        flash[:error] = t("admin.flash.error", :name => @model_config.label, :action => t("admin.actions.deleted"))
      end

      redirect_to index_path(:model_name => @abstract_model.to_param)
    end

    def export
      # todo
      #   limitation: need to display at least one real attribute ('only') so that the full object doesn't get displayed, a way to fix this? maybe force :only => [""]
      #   use send_file instead of send_data to leverage the x-sendfile header set by rails 3 (generate and let the front server handle the rest)
      # maybe
      #   n-levels (backend: possible with xml&json, frontend: not possible?)
      @authorization_adapter.authorize(:export, @abstract_model) if @authorization_adapter

      if format = params[:json] && :json || params[:csv] && :csv || params[:xml] && :xml
        request.format = format
        @schema = params[:schema].symbolize if params[:schema] # to_json and to_xml expect symbols for keys AND values.
        index
      else
        @page_name = t("admin.actions.export").capitalize + " " + @model_config.label_plural.downcase
        @page_type = @abstract_model.pretty_name.downcase

        render :action => 'export'
      end
    end

    def bulk_action
      redirect_to index_path, :flash => { :info => t("admin.flash.noaction") } and return if params[:bulk_ids].blank?
      case params[:bulk_action]
      when "delete" then bulk_delete
      when "export" then export
      else redirect_to(index_path(:model_name => @abstract_model.to_param), :flash => { :info => t("admin.flash.noaction") })
      end
    end

    def bulk_delete
      @authorization_adapter.authorize(:bulk_delete, @abstract_model) if @authorization_adapter
      @page_name = t("admin.actions.delete").capitalize + " " + @model_config.label.downcase
      @page_type = @abstract_model.pretty_name.downcase

      @bulk_objects = list_entries

      render :action => 'bulk_delete'
    end

    def bulk_destroy
      @authorization_adapter.authorize(:bulk_destroy, @abstract_model) if @authorization_adapter

      scope = @authorization_adapter && @authorization_adapter.query(params[:action].to_sym, @abstract_model)

      processed_objects = @abstract_model.destroy(params[:bulk_ids], scope)

      destroyed = processed_objects.select(&:destroyed?)
      not_destroyed = processed_objects - destroyed

      destroyed.each do |object|
        message = "Destroyed #{@model_config.with(:object => object).object_label}"
        AbstractHistory.create_history_item(message, object, @abstract_model, _current_user)
      end

      unless destroyed.empty?
        flash[:success] = t("admin.flash.successful", :name => pluralize(destroyed.count, @model_config.label), :action => t("admin.actions.deleted"))
      end

      unless not_destroyed.empty?
        flash[:error] = t("admin.flash.error", :name => pluralize(not_destroyed.count, @model_config.label), :action => t("admin.actions.deleted"))
      end

      redirect_to index_path
    end

    private

    def get_bulk_objects(ids)
      scope = @authorization_adapter && @authorization_adapter.query(params[:action].to_sym, @abstract_model)
      objects = @abstract_model.get_bulk(ids, scope)

      not_found unless objects
      objects
    end

    def get_sort_hash
      params[:sort] = params[:sort_reverse] = nil unless @model_config.list.with(:view => self, :object => @abstract_model.model.new).visible_fields.map {|f| f.name.to_s}.include? params[:sort]

      params[:sort] ||= @model_config.list.sort_by.to_s
      params[:sort_reverse] ||= 'false'

      field = @model_config.list.fields.find{ |f| f.name.to_s == params[:sort] }

      column = if field.nil? || field.sortable == true # use params[:sort] on the base table
        "#{@abstract_model.model.table_name}.#{params[:sort]}"
      elsif field.sortable == false # use default sort, asked field is not sortable
        "#{@abstract_model.model.table_name}.#{@model_config.list.sort_by.to_s}"
      elsif field.sortable.is_a?(String) && field.sortable.include?('.') # just provide sortable, don't do anything smart
        field.sortable
      elsif field.sortable.is_a?(Hash) # just join sortable hash, don't do anything smart
        "#{field.sortable.keys.first}.#{field.sortable.values.first}"
      elsif field.association? # use column on target table
        "#{field.associated_model_config.abstract_model.model.table_name}.#{field.sortable}"
      else # use described column in the field conf.
        "#{@abstract_model.model.table_name}.#{field.sortable}"
      end

      reversed_sort = (field ? field.sort_reverse? : @model_config.list.sort_reverse?)
      {:sort => column, :sort_reverse => (params[:sort_reverse] == reversed_sort.to_s)}
    end


    # TODO MOVE TO ActiveRecord
    def get_conditions_hash(query, filters)

      # TODO for filtering engine
      #   use a hidden field to store serialized params and send them through post (pagination, export links, show all link, sort links)
      #   Tricky cases where:
      #     query can't be made on any of the available attributes (will it happen a lot Error messages?)
      #     filter can't apply to the targetted attribute (should be sanitized front)
      #   extend engine to :
      #      belongs_to autocomplete id (optionnal)

      #  LATER
      #   find a way for complex request (OR/AND)?
      #   _type should be a dropdown with possible values
      #   belongs_to should be filtering boxes
      #   so that we can create custom engines through the DSL (list.filter = [list of columns])
      #   multiple words queries
      #   find a way to force a column nonetheless?

      # TODO else
      #   has_one ?
      #   polymorphic ?


      return {} if query.blank? && filters.blank? # perf

      @like_operator =  "ILIKE" if ActiveRecord::Base.configurations[Rails.env]['adapter'] == "postgresql"
      @like_operator ||= "LIKE"

      query_statements = []
      filters_statements = []
      values = []
      conditions = [""]

      if query.present?
        queryable_fields = @model_config.list.fields.select(&:queryable?)
        queryable_fields.each do |field|
          searchable_columns = field.searchable_columns.flatten
          searchable_columns.each do |field_infos|
            statement, value1, value2 = build_statement(field_infos[:column], field_infos[:type], query, field.search_operator)
            if statement
              query_statements << statement
              values << value1 unless value1.nil?
              values << value2 unless value2.nil?
            end
          end
        end
      end

      unless query_statements.empty?
        conditions[0] += " AND " unless conditions == [""]
        conditions[0] += "(#{query_statements.join(" OR ")})"  # any column field will do
      end

      if filters.present?
        @filterable_fields = @model_config.list.fields.select(&:filterable?).inject({}){ |memo, field| memo[field.name.to_sym] = field.searchable_columns; memo }
        filters.each_pair do |field_name, filters_dump|
          filters_dump.each do |filter_index, filter_dump|
            field_statements = []
            @filterable_fields[field_name.to_sym].each do |field_infos|
              unless filter_dump[:disabled]
                statement, value1, value2 = build_statement(field_infos[:column], field_infos[:type], filter_dump[:value], (filter_dump[:operator] || 'default'))
                if statement
                  field_statements << statement
                  values << value1 unless value1.nil?
                  values << value2 unless value2.nil?
                end
              end
            end
            filters_statements << "(#{field_statements.join(' OR ')})" unless field_statements.empty?
          end
        end
      end

      unless filters_statements.empty?
       conditions[0] += " AND " unless conditions == [""]
       conditions[0] += "#{filters_statements.join(" AND ")}" # filters should all be true
      end
      
      conditions += values
      conditions != [""] ? { :conditions => conditions } : {}
    end

    def build_statement(column, type, value, operator)

      # this operator/value has been discarded (but kept in the dom to override the one stored in the various links of the page)
      return if operator == '_discard' || value == '_discard'

      # filtering data with unary operator, not type dependent
      if operator == '_blank' || value == '_blank'
        return ["(#{column} IS NULL OR #{column} = '')"]
      elsif operator == '_present' || value == '_present'
        return ["(#{column} IS NOT NULL AND #{column} != '')"]
      elsif operator == '_null' || value == '_null'
        return ["(#{column} IS NULL)"]
      elsif operator == '_not_null' || value == '_not_null'
        return ["(#{column} IS NOT NULL)"]
      elsif operator == '_empty' || value == '_empty'
        return ["(#{column} = '')"]
      elsif operator == '_not_empty' || value == '_not_empty'
        return ["(#{column} != '')"]
      end

      # now we go type specific
      case type
      when :boolean
        return ["(#{column} IS NULL OR #{column} = ?)", false] if ['false', 'f', '0'].include?(value)
        return ["(#{column} = ?)", true] if ['true', 't', '1'].include?(value)
      when :integer, :belongs_to_association
        return if value.blank?
        ["(#{column} = ?)", value.to_i] if value.to_i.to_s == value
      when :string, :text
        return if value.blank?
        value = case operator
        when 'default', 'like'
          "%#{value}%"
        when 'starts_with'
          "#{value}%"
        when 'ends_with'
          "%#{value}"
        when 'is', '='
          "#{value}"
        end
        ["(#{column} #{@like_operator} ?)", value]
      when :datetime, :timestamp, :date
        return unless operator != 'default'
        values = case operator
        when 'today'
          [Date.today.beginning_of_day, Date.today.end_of_day]
        when 'yesterday'
          [Date.yesterday.beginning_of_day, Date.yesterday.end_of_day]
        when 'this_week'
          [Date.today.beginning_of_week.beginning_of_day, Date.today.end_of_week.end_of_day]
        when 'last_week'
          [1.week.ago.to_date.beginning_of_week.beginning_of_day, 1.week.ago.to_date.end_of_week.end_of_day]
        when 'less_than'
          return if value.blank?
          [value.to_i.days.ago, DateTime.now]
        when 'more_than'
          return if value.blank?
          [2000.years.ago, value.to_i.days.ago]
        end
        ["(#{column} BETWEEN ? AND ?)", *values]
      when :enum
        return if value.blank?
        ["(#{column} IN (?))", [value].flatten]
      end
    end

    def get_attributes
      @attributes = params[@abstract_model.to_param.singularize.gsub('~','_')] || {}
      @attributes.each do |key, value|
        # Deserialize the attribute if attribute is serialized
        if @abstract_model.model.serialized_attributes.keys.include?(key) and value.is_a? String
          @attributes[key] = YAML::load(value)
        end
        # Delete fields that are blank
        @attributes[key] = nil if value.blank?
      end
    end

    def redirect_to_on_success
      notice = t("admin.flash.successful", :name => @model_config.label, :action => t("admin.actions.#{params[:action]}d"))
      if params[:_add_another]
        redirect_to new_path, :flash => { :success => notice }
      elsif params[:_add_edit]
        redirect_to edit_path(:id => @object.id), :flash => { :success => notice }
      else
        redirect_to index_path, :flash => { :success => notice }
      end
    end

    def handle_save_error whereto = :new
      action = params[:action]

      flash.now[:error] = t("admin.flash.error", :name => @model_config.label, :action => t("admin.actions.#{action}d"))
      flash.now[:error] += ". #{@object.errors[:base].to_sentence}" unless @object.errors[:base].blank?

      respond_to do |format|
        format.html { render whereto, :status => :not_acceptable }
        format.js   { render whereto, :layout => false, :status => :not_acceptable  }
      end
    end

    def check_for_cancel
      redirect_to index_path, :flash => { :warning => t("admin.flash.noaction") } if params[:_continue]
    end

    def list_entries(other = {})
      return get_bulk_objects(params[:bulk_ids]) if params[:bulk_ids].present?

      associations = @model_config.list.fields.select {|f| f.type == :belongs_to_association && !f.polymorphic? }.map {|f| f.association[:name] }
      options = get_sort_hash.merge(get_conditions_hash(params[:query], params[:filters])).merge(other).merge(associations.empty? ? {} : { :include => associations })

      scope = @authorization_adapter && @authorization_adapter.query(:index, @abstract_model)

      if params[:all]
        objects = @abstract_model.all(options, scope)
      else
        options.merge!(:page => (params[:page] || 1).to_i, :per_page => @model_config.list.items_per_page)
        objects = @abstract_model.paginated(options, scope)
      end
      objects
    end

    def associations_hash
      associations = {}
      @abstract_model.associations.each do |association|
        if [:has_many, :has_and_belongs_to_many].include?(association[:type])
          records = Array(@object.send(association[:name]))
          associations[association[:name]] = records.collect(&:id)
        end
      end
      associations
    end
  end
end
