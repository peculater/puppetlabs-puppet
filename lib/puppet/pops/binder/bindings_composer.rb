# The BindingsComposer handles composition of multiple bindings sources
# It is directed by a {Puppet::Pops::Binder::Config::BinderConfig BinderConfig} that indicates how
# the final composition should be layered, and what should be included/excluded in each layer
#
# The bindings composer is intended to be used once per environment as the compiler starts its work.
#
# TODO: Also ? instead of confdir ? support envdir scheme / relative to environment root (== same as confdir if there is only one environment)
# TODO: If same config is loaded in a higher layer, skip it in the lower (since it is meaningless to load it again with lower
#       precedence
# TODO: BindingsConfig, and default BindingsConfig via settings
#
class Puppet::Pops::Binder::BindingsComposer

  # The BindingsConfig instance holding the read and parsed, but not evaluated configuration
  # @api public
  #
  attr_reader :config

  # map of scheme name to handler
  # @api private
  attr_reader :scheme_handlers

  # @return Hash<String, Puppet::Module> map of module name to module instance
  # @api private
  attr_reader :name_to_module

  # @api private
  attr_reader :confdir

  # @api private
  attr_reader :diagnostics

  # Container of all warnings and errors produced while initializing and loading bindings
  #
  # @api public
  attr_reader :acceptor

  def initialize()
    @acceptor = Puppet::Pops::Validation::Acceptor.new()
    @diagnostics = Puppet::Pops::Binder::Config::DiagnosticProducer.new(acceptor)
    @config = Puppet::Pops::Binder::Config::BinderConfig.new(@diagnostics)
    if acceptor.errors?
      Puppet::Pops::IssueReporter.assert_and_report(acceptor, :message => 'Binding Composer: error while reading config.')
      raise Puppet::DevError.new("Internal Error: IssueReporter did not raise exception for errors in bindings config.")
    end
  end

  # @return [Puppet::Pops::Binder::Bindings::LayeredBindings]
  def compose(scope)
    # Configure the scheme handlers.
    # Do this now since there is a scope (which makes it possible to get to other information
    # TODO: Make it possible to register scheme handlers
    #
    @scheme_handlers = {
      'module-hiera'  => ModuleHieraScheme.new(self),
      'confdir-hiera' => ConfdirHieraScheme.new(self),
      'module'        => ModuleScheme.new(self),
      'confdir'       => ConfdirScheme.new(self)
    }

    # get all existing modules and their root path
    @name_to_module = {}
    scope.environment.modules.each {|mod| name_to_module[mod.name] = mod }

    # setup the confdir
    @confdir = Puppet.settings[:confdir]

    factory = Puppet::Pops::Binder::BindingsFactory
    contributions = []
    configured_layers = @config.layering_config.collect do |  layer_config |
      # get contributions with effective categories
      contribs = configure_layer(layer_config, scope, diagnostics)
      # collect the contributions separately for later checking of category precedence
      contributions.concat(contribs)
      # create a named layer with all the bindings for this layer
      factory.named_layer(layer_config['name'], *contribs.collect {|c| c.bindings }.flatten)
    end

    # must check all contributions are based on compatible category precedence
    # (Note that contributions no longer contains the bindings as a side effect of setting them in the collected
    # layer. The effective categories and the name remains in the contributed model; this is enough for checking
    # and error reporting).
    check_contribution_precedence(contributions)

    # Add the two system layers; the final - highest ("can not be overridden" layer), and the lowest
    # Everything here can be overridden 'default' layer.
    #
    configured_layers.insert(0, Puppet::Pops::Binder::SystemBindings.final_contribution)
    configured_layers.insert(-1, Puppet::Pops::Binder::SystemBindings.default_contribution)

    # and finally... create the resulting structure
    factory.layered_bindings(*configured_layers)
  end

  # Evaluates configured categorization and returns the result.
  # The result is not cached.
  # @api public
  #
  def effective_categories(scope)
    evaluated_categories = []
    unevaluated_categories = @config.categorization
    parser = Puppet::Pops::Parser::EvaluatingParser.new()
    result = unevaluated_categories.collect do |category_tuple|
      result = [ category_tuple[0], parser.evaluate_string( scope, parser.quote( category_tuple[1] )) ]
      if result[1].is_a?(String)
        # category values are always in lower case
        result[1] = result[1].downcase
      else
        raise ArgumentError, "Categorization value must be a string, category #{result[0]} evaluation resulted in a: '#{result[1].class}'"
      end
      result
    end
    Puppet::Pops::Binder::BindingsFactory::categories(result)
  end

  private

  # Checks that contribution's effective categorization is in the same relative order as in the overall
  # categorization precedence.
  #
  def check_contribution_precedence(contributions)
    cat_prec = { }
    @config.categorization.each_with_index {|c, i| cat_prec[ c[0] ] = i }
    contributions.each() do |contrib|
      # Contributions that do not specify their opinion about categorization silently accepts the precedence
      # set in the root configuration - and may thus produce an unexpected result
      #
      next unless ec = contrib.effective_categories
      next unless categories = ec.categories
      prev_prec = -1
      categories.each do |c|
        prec = cat_prec[c.categorization]
        issues = Puppet::Pops::Binder::BinderIssues
        unless prec
          diagnostics.accept(issues::MISSING_CATEGORY_PRECEDENCE, c, :categorization => c.categorization)
          next
        end
        unless prec > prev_prec
          diagnostics.accept(issues::PRECEDENCE_MISMATCH_IN_CONTRIBUTION, c, :categorization => c.categorization)
        end
        prev_prec = prec
      end
    end
  end

  def configure_layer(layer_description, scope, diagnostics)
    name = layer_description['name']

    # compute effective set of uris to load (and get rid of any duplicates in the process
    included_uris = array_of_uris(layer_description['include'])
    excluded_uris = array_of_uris(layer_description['exclude'])
    effective_uris = Set.new(expand_included_uris(included_uris)).subtract(Set.new(expand_excluded_uris(excluded_uris)))

    # Each URI should result in a ContributedBindings
    effective_uris.collect { |uri| scheme_handlers[uri.scheme].contributed_bindings(uri, scope, diagnostics) }
  end

  def array_of_uris(descriptions)
    return [] unless descriptions
    descriptions = [descriptions] unless descriptions.is_a?(Array)
    descriptions.collect {|d| URI.parse(d) }
  end

  def expand_included_uris(uris)
    result = []
    uris.each do |uri|
      unless handler = scheme_handlers[uri.scheme]
        raise ArgumentError, "Unknown bindings provider scheme: '#{uri.scheme}'"
      end
      result.concat(handler.expand_included(uri))
    end
    result
  end

  def expand_excluded_uris(uris)
    result = []
    uris.each do |uri|
      unless handler = scheme_handlers[uri.scheme]
        raise ArgumentError, "Unknown bindings provider scheme: '#{uri.scheme}'"
      end
      result.concat(handler.expand_excluded(uri))
    end
    result
  end

end

# @abstract
class BindingsProviderScheme
  attr_reader :composer
  def initialize(composer)
    @composer = composer
  end

  # @return [Boolean] whether the uri is an optional reference or not.
  def is_optional?(uri)
    (query = uri.query) && query == '' || query == 'optional'
  end
end

class SymbolicScheme < BindingsProviderScheme

  # Shared implementation for module: and confdir: since the distinction is only in checks if a symbolic name
  # exists as a loadable file or not. Once this method is called it is assumed that the name is relativeized
  # and that it should exist relative to all loadable ruby locations.
  # 
  # TODO: this needs to be changed once ARM-8 Puppet DSL concrete syntax is also supported.
  #
  def contributed_bindings(uri, scope, diagnostics)
    fqn = fqn_from_path(uri)[1]
    bindings = Puppet::Pops::Binder::BindingsLoader.provide(scope, fqn)
    raise ArgumentError, "Cannot load bindings '#{uri}' - no bindings found." unless bindings
    # Must clone as the the rest mutates the model
    cloned_bindings = Marshal.load(Marshal.dump(bindings))
    # Give no effective categories (i.e. ok with whatever categories there is)
    Puppet::Pops::Binder::BindingsFactory.contributed_bindings(fqn, cloned_bindings, nil)
  end

  # @api private
  def fqn_from_path(uri)
    split_path = uri.path.split('/')
    if split_path.size > 1 && split_path[-1].empty?
      split_path.delete_at(-1)
    end

    fqn = split_path[ 1 ]
    raise ArgumentError, "Module scheme binding reference has no name." unless fqn
    split_name = fqn.split('::')
    # drop leading '::'
    split_name.shift if split_name[0] && split_name[0].empty?
    [split_name, split_name.join('::')]
  end
end

# TODO: optional does not work with non modulepath located content - it assumes modulepath + name=> path
class ModuleScheme < SymbolicScheme
  def expand_included(uri)
    result = []
    split_name, fqn = fqn_from_path(uri)

    # supports wild card in the module name
    case split_name[0]
    when '*'
      # create new URIs, one per module name that has a corresponding .rb file relative to its
      # '<root>/lib/puppet/bindings/'
      #
      composer.name_to_module.each_pair do | mod_name, mod |
        expanded_name_parts = [mod_name] + split_name[1..-1]
        expanded_name = expanded_name_parts.join('::')
        if Puppet::Pops::Binder::BindingsLoader.loadable?(mod.path, expanded_name)
          result << URI.parse('module:/' + expanded_name)
        end
      end
    when nil
      raise ArgumentError, "Bad bindings uri, the #{uri} has neither module name or wildcard '*' in its first path position"
    else
      joined_name = split_name.join('::')
      # skip optional uri if it does not exist
      if is_optional?(uri)
        mod = composer.name_to_module[split_name[0]]
        if mod && Puppet::Binder::BindingsLoader.loadable?(mod.path, joined_name)
          result << URI.parse('module:/' + joined_name)
        end
      else
        # assume it exists (do not give error if not, since it may be excluded later)
        result << URI.parse('module:/' + joined_name)
      end
    end
    result
  end

  def expand_excluded(uri)
    result = []
    split_name, fqn = fqn_from_path(uri)

    case split_name[ 0 ]
    when '*'
      # create new URIs, one per module name
      composer.name_to_module.each_pair do | name, mod |
        result << URI.parse('module:/' + ([name] + split_name).join('::'))
      end

    when nil
      raise ArgumentError, "Bad bindings uri, the #{uri} has neither module name or wildcard '*' in its first path position"
    else
      # create a clean copy (get rid of optional, fragments etc. and any trailing stuff
      result << URI.parse('module:/' + split_name.join('::'))
    end
    result
  end
end

class ConfdirScheme < SymbolicScheme

  # Similar to ModuleScheme, but relative to the config root. Does not support wildcard expansion
  # TODO: optional does not work with non confdir located files
  #
  def expand_included(uri)
    fqn = fqn_from_path(uri)[1]
    if is_optional?(uri)
      if Puppet::Binder::BindingsLoader.loadable?(composer.confdir, fqn)
        [URI.parse('module:/' + fqn)]
      else
        []
      end
    else
      # assume it exists (do not give error if not, since it may be excluded later)
      [URI.parse('module:/' + fqn)]
    end
  end

  def expand_excluded(uri)
    [URI.parse("confdir:/#{fqn_from_path(uri)[1]}")]
  end

end

# @abstract
class HieraScheme < BindingsProviderScheme
end

# TODO: Handle the case when confdir points to a Hiera1 hiera_conf.yaml file
# 
class ConfdirHieraScheme < HieraScheme
  def contributed_bindings(uri, scope, diagnostics)
    split_path = uri.path.split('/')
    name = split_path[1]
    confdir = composer.confdir
    provider = Puppet::Pops::Binder::Hiera2::BindingsProvider.new(uri.to_s, File.join(confdir, uri.path), composer.acceptor)
    provider.load_bindings(scope)
  end

  # Similar to ModuleHieraScheme, but relative to the config root. Does not support wildcard expansion
  def expand_included(uri)
    # Skip if optional and does not exist
    # Skip if a hiera 1
    #
    # TODO: handle optional
    [uri]
  end

  def expand_excluded(uri)
    [uri]
  end
end

# The module hiera scheme uses the path to denote a directory relative to a module root
# The path starts with the name of the module, or '*' to denote *any module*.
# @example All root hiera.yaml from all modules
#   module-hiera:/*
# @example The hiera.yaml from the module `foo`'s relative path `<foo root>/bar`
#   module-hiera:/foo/bar
#
class ModuleHieraScheme < HieraScheme
  # @return [Puppet::Pops::Binder::Bindings::ContributedBindings] the bindings contributed from the config
  def contributed_bindings(uri, scope, diagnostics)
    split_path = uri.path.split('/')
    name = split_path[1]
    mod = composer.name_to_module[name]
    provider = Puppet::Pops::Binder::Hiera2::BindingsProvider.new(uri.to_s, File.join(mod.path, split_path[ 2..-1 ]), composer.acceptor)
    provider.load_bindings(scope)
  end

  def expand_included(uri)
    result = []
    split_path = uri.path.split('/')
    if split_path.size > 1 && split_path[-1].empty?
      split_path.delete_at(-1)
    end

    # 0 = "", since a URI with a path must start with '/'
    # 1 = '*' or the module name
    case split_path[ 1 ]
    when '*'
      # create new URIs, one per module name that has a hiera.yaml file relative to its root
      composer.name_to_module.each_pair do | name, mod |
        if File.exist?(File.join(mod.path, split_path[ 2..-1 ], 'hiera.yaml' ))
          path_parts =["", name] + split_path[2..-1]
          result << URI.parse('module-hiera:'+File.join(path_parts))
        end
      end
    when nil
      raise ArgumentError, "Bad bindings uri, the #{uri} has neither module name or wildcard '*' in its first path position"
    else
      # If uri has query that is empty, or the text 'optional' skip this uri if it does not exist
      if query = uri.query()
        if query == '' || query == 'optional'
          if File.exist?(File.join(mod.path, split_path[ 2..-1 ], 'hiera.yaml' ))
            result << URI.parse('module-hiera:' + uri.path)
          end
        end
      else
        # assume it exists (do not give error since it may be excluded later)
        result << URI.parse('module-hiera:' + File.join(split_path))
      end
    end
    result
  end

  def expand_excluded(uri)
    result = []
    split_path = uri.path.split('/')
    if split_path.size > 1 && split_path[-1].empty?
      split_path.delete_at(-1)
    end

    # 0 = "", since a URI with a path must start with '/'
    # 1 = '*' or the module name
    case split_path[ 1 ]
    when '*'
      # create new URIs, one per module name that has a hiera.yaml file relative to its root
      composer.name_to_module.each_pair do | name, mod |
        path_parts =["", mod.name] + split_path[2..-1]
        result << URI.parse('module-hiera:'+File.join(path_parts))
      end

    when nil
      raise ArgumentError, "Bad bindings uri, the #{uri} has neither module name or wildcard '*' in its first path position"
    else
      # create a clean copy (get rid of optional, fragments etc. and a trailing "/")
      result << URI.parse('module-hiera:' + File.join(split_path))
    end
    result
  end
end

