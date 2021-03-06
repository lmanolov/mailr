require 'will_paginate/finders/base'
require 'active_record'

module WillPaginate::Finders
  # = Paginating finders for ActiveRecord models
  # 
  # WillPaginate adds +paginate+, +per_page+ and other methods to
  # ActiveRecord::Base class methods and associations. It also hooks into
  # +method_missing+ to intercept pagination calls to dynamic finders such as
  # +paginate_by_user_id+ and translate them to ordinary finders
  # (+find_all_by_user_id+ in this case).
  # 
  # In short, paginating finders are equivalent to ActiveRecord finders; the
  # only difference is that we start with "paginate" instead of "find" and
  # that <tt>:page</tt> is required parameter:
  #
  #   @posts = Post.paginate :all, :page => params[:page], :order => 'created_at DESC'
  # 
  # In paginating finders, "all" is implicit. There is no sense in paginating
  # a single record, right? So, you can drop the <tt>:all</tt> argument:
  # 
  #   Post.paginate(...)              =>  Post.find :all
  #   Post.paginate_all_by_something  =>  Post.find_all_by_something
  #   Post.paginate_by_something      =>  Post.find_all_by_something
  #
  # == The importance of the <tt>:order</tt> parameter
  #
  # In ActiveRecord finders, <tt>:order</tt> parameter specifies columns for
  # the <tt>ORDER BY</tt> clause in SQL. It is important to have it, since
  # pagination only makes sense with ordered sets. Without the <tt>ORDER
  # BY</tt> clause, databases aren't required to do consistent ordering when
  # performing <tt>SELECT</tt> queries; this is especially true for
  # PostgreSQL.
  #
  # Therefore, make sure you are doing ordering on a column that makes the
  # most sense in the current context. Make that obvious to the user, also.
  # For perfomance reasons you will also want to add an index to that column.
  module ActiveRecord
    include WillPaginate::Finders::Base
    
    # Wraps +find_by_sql+ by simply adding LIMIT and OFFSET to your SQL string
    # based on the params otherwise used by paginating finds: +page+ and
    # +per_page+.
    #
    # Example:
    # 
    #   @developers = Developer.paginate_by_sql ['select * from developers where salary > ?', 80000],
    #                          :page => params[:page], :per_page => 3
    #
    # A query for counting rows will automatically be generated if you don't
    # supply <tt>:total_entries</tt>. If you experience problems with this
    # generated SQL, you might want to perform the count manually in your
    # application.
    # 
    def paginate_by_sql(sql, options)
      WillPaginate::Collection.create(*wp_parse_options(options)) do |pager|
        query = sanitize_sql(sql.dup)
        original_query = query.dup
        # add limit, offset
        add_limit! query, :offset => pager.offset, :limit => pager.per_page
        # perfom the find
        pager.replace find_by_sql(query)
        
        unless pager.total_entries
          count_query = original_query.sub /\bORDER\s+BY\s+[\w`,\s]+$/mi, ''
          count_query = "SELECT COUNT(*) FROM (#{count_query})"
          
          unless ['oracle', 'oci'].include?(self.connection.adapter_name.downcase)
            count_query << ' AS count_table'
          end
          # perform the count query
          pager.total_entries = count_by_sql(count_query)
        end
      end
    end

    def respond_to?(method, include_priv = false) #:nodoc:
      super(method.to_s.sub(/^paginate/, 'find'), include_priv)
    end

  protected
    
    def method_missing_with_paginate(method, *args, &block) #:nodoc:
      # did somebody tried to paginate? if not, let them be
      unless method.to_s.index('paginate') == 0
        return method_missing_without_paginate(method, *args, &block) 
      end
      
      # paginate finders are really just find_* with limit and offset
      finder = method.to_s.sub('paginate', 'find')
      finder.sub!('find', 'find_all') if finder.index('find_by_') == 0
      
      options = args.pop
      raise ArgumentError, 'parameter hash expected' unless options.respond_to? :symbolize_keys
      options = options.dup
      options[:finder] = finder
      args << options
      
      paginate(*args, &block)
    end

    def wp_query(options, pager, args, &block)
      finder = (options.delete(:finder) || 'find').to_s
      find_options = options.except(:count).update(:offset => pager.offset, :limit => pager.per_page) 

      if finder == 'find'
        if Array === args.first and !pager.total_entries
          pager.total_entries = args.first.size
        end
        args << :all if args.empty?
      end
      
      args << find_options
      pager.replace send(finder, *args, &block)
      
      unless pager.total_entries
        # magic counting
        pager.total_entries = wp_count(options, args, finder) 
      end
    end

    # Does the not-so-trivial job of finding out the total number of entries
    # in the database. It relies on the ActiveRecord +count+ method.
    def wp_count(options, args, finder)
      # find out if we are in a model or an association proxy
      klass = (@owner and @reflection) ? @reflection.klass : self
      count_options = wp_parse_count_options(options, klass)

      # we may have to scope ...
      counter = Proc.new { count(count_options) }

      count = if finder.index('find_') == 0 and klass.respond_to?(scoper = finder.sub('find', 'with'))
                # scope_out adds a 'with_finder' method which acts like with_scope, if it's present
                # then execute the count with the scoping provided by the with_finder
                send(scoper, &counter)
              elsif finder =~ /^find_(all_by|by)_([_a-zA-Z]\w*)$/
                # extract conditions from calls like "paginate_by_foo_and_bar"
                attribute_names = $2.split('_and_')
                conditions = construct_attributes_from_arguments(attribute_names, args)
                with_scope(:find => { :conditions => conditions }, &counter)
              else
                counter.call
              end

      count.respond_to?(:length) ? count.length : count
    end
    
    def wp_parse_count_options(options, klass)
      excludees = [:count, :order, :limit, :offset, :readonly]
      
      unless ::ActiveRecord::Calculations::CALCULATIONS_OPTIONS.include?(:from)
        # :from parameter wasn't supported in count() before this change
        excludees << :from
      end
      
      # Use :select from scope if it isn't already present.
      options[:select] = scope(:find, :select) unless options[:select]
      
      if options[:select] and options[:select] =~ /^\s*DISTINCT\b/i
        # Remove quoting and check for table_name.*-like statement.
        if options[:select].gsub('`', '') =~ /\w+\.\*/
          options[:select] = "DISTINCT #{klass.table_name}.#{klass.primary_key}"
        end
      else
        excludees << :select
      end
      
      # count expects (almost) the same options as find
      count_options = options.except *excludees

      # merge the hash found in :count
      # this allows you to specify :select, :order, or anything else just for the count query
      count_options.update options[:count] if options[:count]
      
      # forget about includes if they are irrelevant (Rails 2.1)
      if count_options[:include] and
          klass.private_methods.include?('references_eager_loaded_tables?') and
          !klass.send(:references_eager_loaded_tables?, count_options)
        count_options.delete :include
      end
      
      count_options
    end
  end
end

ActiveRecord::Base.class_eval do
  extend WillPaginate::Finders::ActiveRecord
  class << self
    alias_method_chain :method_missing, :paginate
  end
end

# support pagination on associations
a = ActiveRecord::Associations
returning([ a::AssociationCollection ]) { |classes|
  # detect http://dev.rubyonrails.org/changeset/9230
  unless a::HasManyThroughAssociation.superclass == a::HasManyAssociation
    classes << a::HasManyThroughAssociation
  end
}.each do |klass|
  klass.send :include, WillPaginate::Finders::ActiveRecord
  klass.class_eval { alias_method_chain :method_missing, :paginate }
end
