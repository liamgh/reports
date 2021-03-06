package EPrints::Plugin::Screen::Report;

# Abstract class that handles the Report tools

use JSON qw();
use EPrints::Plugin::Screen;
@ISA = ( 'EPrints::Plugin::Screen' );

use strict;

sub new
{
	my( $class, %params ) = @_;

	my $self = $class->SUPER::new(%params);

	push @{$self->{actions}}, qw( export search );

	$self->{sconf} = "report";

        $self->{appears} = [
                {
                        place => "key_tools",
                        position => 1000,
                },
        ];

	return $self;
}

sub get_report { shift->{report} }

sub can_be_viewed
{
        my( $self ) = @_;

	return 1 if( $self->{public} ); #allow a report to be publicly available

	return 0 if( !defined $self->{repository}->current_user );
	
	return $self->allow( 'report' );
}

sub allow_export { shift->can_be_viewed }
sub action_export {}

sub wishes_to_export {
	$_[0]->repository->param( 'export' ) ||
	$_[0]->repository->param( 'ajax' );
}

sub export_mimetype
{
	my( $self ) = @_;

	my $plugin = $self->{processor}->{plugin};
	if( !defined $plugin )
	{
		if( $self->repository->param( "ajax" ) )
		{
			return "application/json; charset=utf-8";
		}
	
		return "text/html; charset=utf-8";
	}

	return $plugin->param( "mimetype" );
}

sub export
{
	my( $self ) = @_;

	my $part = $self->repository->param( "ajax" );
	my $f = "ajax_$part";

	if( $self->can( $f ) )
	{
		binmode(STDOUT, ":utf8");
		return $self->$f;
	}

	my $plugin = $self->{processor}->{plugin};
	return $self->SUPER::export if !defined $plugin;

	$plugin->initialise_fh( \*STDOUT );
	$plugin->output_list(
		list => $self->items,
		fh => \*STDOUT,
		exportfields => $self->{processor}->{exportfields},
		dataset => $self->{processor}->{dataset},
		plugin => $self,
	);
}

sub allow_search { return 1; }

#generates search config
sub _create_search
{
	my( $self ) = @_;

	my $session = $self->{session};
        my $report_plugin = $self->{processor}->screen;
	# Do not create a search config if this is not configured in the report
	return if ! defined $report_plugin->{searchdatasetid};
        
	$self->{processor}->{report_plugin} = $report_plugin;
	
        my $report_ds = $session->dataset( $report_plugin->{searchdatasetid} );
        if( defined $report_ds )
        {
                $self->{processor}->{datasetid} = $report_ds->base_id;

                my $sconf = $report_ds->search_config( $report_plugin->{sconf} );
                my $format = "report/" . $report_ds->base_id;
                $self->{processor}->{search} = $session->plugin( "Search" )->plugins(
                        {
                                keep_cache => 1,
                                session => $self->{session},
                                dataset => $report_ds,
                                %{$sconf}
                        },
                        type => "Search",
                        can_search => $format,
                );
	}
}

sub action_search
{
	my( $self ) = @_;

	$self->{processor}->{action} = "search";

	#read parameters
	my $session = $self->{session};

	$self->{processor}->{report} = $session->param( 'report' );

	$self->{processor}->{screenid} = $self->{processor}->{report};
	$self->_create_search;

	my $loaded = 0;
        my $id = $session->param( "cache" );
        if( defined $id )
        {
		$loaded = $self->{processor}->{search}->from_cache( $id );
        }

        if( !$loaded )
        {
                my $exp = $session->param( "exp" );
                if( defined $exp )
                {
			$self->{processor}->{search}->from_string( $exp );
                        # cache expired...
                        $loaded = 1;
                }
        }

        my @problems;
        if( !$loaded )
        {
		for( $self->{processor}->{search}->from_form )
                        {
                                $self->{processor}->add_message( "warning", $_ );
                        }
        }
          

	#display the results
	$self->render;
}

sub properties_from
{
	my( $self ) = @_;

	my $repo = $self->repository;
	$self->SUPER::properties_from;

	if( defined ( my $dsid = $self->param( "datasetid" ) ) )
	{
		$self->{processor}->{dataset} = $self->repository->dataset( $dsid );
	}

	# sf2 - TODO - bark if dataset is not set? perhaps there are other ways to get the objects from...


	my $report = $self->get_report();

	#get a search object if we have one from a previous search action, so that we might later use it to do an export action
	$self->_create_search;	
	if( defined $self->repository->param( "search" ) )
	{
		$self->{processor}->{search}->from_string( $self->repository->param( "search" ) ) if defined $self->{processor}->{search};
		$self->{processor}->{export_search} = 1;
	}
	

	my $format = $self->repository->param( "export" );
	if( $format && $report )
	{
		my $plugin = $self->repository->plugin( "Export::$format", report => $report );
		if( defined $plugin && ( $plugin->can_accept( "report/$report" ) || ($plugin->can_accept( "report/generic" ) ) ) )
		{
			$self->{processor}->{plugin} = $plugin;
		}
	}

	#list of export fields retrieved from non-abstract instances of reports
	my @exportfields;
	if( defined $repo->config( $self->{export_conf}, "exportfields" ) )
	{
		foreach my $fieldnames ( values %{$repo->config( $self->{export_conf}, "exportfields" )} )
		{
			foreach	my $fieldname ( @{$fieldnames} )
			{
				push @exportfields, $fieldname if defined $self->repository->param( $fieldname ); 
			}
		}
	}
	$self->{processor}->{exportfields} = \@exportfields;
}
		
# \@({meta_fields=>[ "field1", "field2" "document.field3" ], merge=>"ANY", match=>"EX", value=>"bees"}, {meta_fields=>[ "field4" ], value=>"honey"});
# e.g.
# return [ { meta_fields => [ 'type' ], value => 'article' } ]
sub filters
{
	return [];
}

# how to select items i.e. the slice of data we want to validate/export?
# 
sub items
{
	my( $self ) = @_;
	if( $self->{processor}->{action} eq "search" || $self->{processor}->{export_search} )
       	{
		my $report = $self->{processor}->{report_plugin};	
		$report->apply_filters if $report->can( 'apply_filters' );
	
		return $self->{processor}->{search}->perform_search;
	}
	elsif( defined $self->{processor}->{dataset} ) 
	{
		my %search_opts = ( filters => $self->filters, satisfy_all => 1 );
		if( defined $self->param( 'custom_order' ) )
		{
			$search_opts{custom_order} = $self->param( 'custom_order' );
		}	
		return $self->{processor}->{dataset}->search( %search_opts );
	}

	# we can't return an EPrints::List if {dataset} is not defined
	return undef;
}

# from Reports/ROS/Journals.pm
# TODO Note quite a lot of replication between this and Export::Report::CSV::output_dataobj
sub validate_dataobj
{
	my( $plugin, $dataobj ) = @_;

	my $repo = $plugin->repository;

	my $report_fields = $plugin->report_fields( $dataobj );
	my $val_fields = $plugin->validate_fields( $dataobj );

	# related objects and their datasets
	my $objects = $plugin->get_related_objects( $dataobj );
	my $valid_ds = {};
	foreach my $dsid ( keys %$objects )
	{
		$valid_ds->{$dsid} = $repo->dataset( $dsid );
	}

	my @problems;

	foreach my $field ( @{ $plugin->report_fields_order( $dataobj ) || [] } )
	{
		# validation action
		my $v_field = $val_fields->{$field};
		next unless defined $v_field; # no validation required

		# simple case - code handles validation
		if( ref( $v_field ) eq 'CODE' )
		{
			# a sub{} we need to run
			eval {
				&$v_field( $plugin, $objects, \@problems );
			};
			if( $@ )
			{
				$repo->log( "Validation Runtime error: $@" );
			}
			next;
		}
		elsif( lc $v_field ne "required" )
		{
			$repo->log( "Validation Runtime error: $v_field must be code ref or 'required'" );
			next;
		}

		# check required values

		my $value; # the value to validate
		my $ep_field = $report_fields->{$field};
		if( ref( $ep_field ) eq 'CODE' )
		{
			# a sub{} we need to run
			eval {
				$value = &$ep_field( $plugin, $objects );
			};
			if( $@ )
			{
				$repo->log( "Validation Runtime error: $@" );
			}
		}
		elsif( $ep_field =~ /^([a-z_]+)\.([0-9a-z_]+)$/ )
		{
			# a straight mapping with an EPrints field
			my( $ds_id, $ep_fieldname ) = ( $1, $2 );
			my $ds = $valid_ds->{$ds_id};

			if( defined $ds && $ds->has_field( $ep_fieldname ) )
			{
				$value = $objects->{$ds_id}->value( $ep_fieldname );
			}
			else
			{
				# dataset or field doesn't exist
				$repo->log( "Validation Runtime error: dataset $ds_id or field $ep_fieldname doesn't exist" );
			}
		}

		# is field set?
		if( !EPrints::Utils::is_set( $value ) )
		{
			push @problems, "Missing required field $field";
		}
	}

	return @problems;
}

# TODO Note copy of Export::Report::get_related_objects
sub get_related_objects
{
	my( $plugin, $dataobj ) = @_;

	my $cmd = [ 'reports', $plugin->get_report, 'get_related_objects' ];
        if( $plugin->repository->can_call( @$cmd ) )
        {
		return $plugin->repository->call( $cmd, $plugin->repository, $dataobj ) || {};
        }

	# just pass the dataobj itself
	return {
		$dataobj->dataset->confid => $dataobj,
	};
}

# TODO Note copy of Export::Report::report_fields_order
sub report_fields_order
{
	my( $plugin ) = @_;

	return $plugin->{report_fields_order} if( defined $plugin->{report_fields_order} );

	my $report = $plugin->get_report();
	return [] unless( defined $report );

	$plugin->{report_fields_order} = $plugin->repository->config( 'reports', $report, 'fields' );

	return $plugin->{report_fields_order};
}

# TODO Note copy of Export::Report::report_fields
sub report_fields
{
	my( $plugin ) = @_;

	return $plugin->{report_fields} if( defined $plugin->{report_fields} );

	my $report = $plugin->get_report();
	return [] unless( defined $report );

	$plugin->{report_fields} = $plugin->repository->config( 'reports', $report, 'mappings' );

	return $plugin->{report_fields};
}

sub validate_fields
{
	my( $plugin ) = @_;

	return $plugin->{validate_fields} if( defined $plugin->{validate_fields} );

	my $report = $plugin->get_report();
	return [] unless( defined $report );

	$plugin->{validate_fields} = $plugin->repository->config( 'reports', $report, 'validate' );

	return $plugin->{validate_fields};
}

## rendering

# The "splash page"
sub render_splash_page
{
	my( $self ) = @_;

	my $repo = $self->repository;
	my @plugins = $self->report_plugins;

	if( !scalar( @plugins ) )
	{
		return $self->html_phrase( "no_reports" );
	}

	my @labels;
	my @panels;

	#preset reports
	push @labels, $repo->html_phrase( "reports_preset" );
	my $preset = $repo->make_element( "div" );

	# top category: by classname > Report::ROS::SomeReport1, Report::ROS::SomeReport2

	my $ul = $self->repository->make_element( 'ul', class => 'ep_report_category' );

	# cat ~ category - !meeow
	my $cat = "";
	my $cat_li = undef; 
	my $cat_ul = undef;

	foreach my $report_plugin ( sort { $a->get_subtype cmp $b->get_subtype } @plugins )
	{
		my $plugin_cat = $report_plugin->get_subtype;
		$plugin_cat =~ s/^Report::([^:]+):?:?(.*)$/$1/g;

		# render top-category, if needed	
		if( $cat ne $plugin_cat )
		{
			$cat = $plugin_cat;
			$cat_ul = undef;

			$cat_li = $ul->appendChild( $self->repository->make_element( 'li' ) );
			$cat_li->appendChild( $self->repository->html_phrase( "Plugin/Screen/Report/$cat:title" ) );
		}

		if( EPrints::Utils::is_set( $2 ) )
		{
			# then we hit a sub-plugin eg. Screen::Report::$category::$report <- $2 == $report here
			if( !defined $cat_ul )
			{
				$cat_ul = $cat_li->appendChild( $self->repository->make_element( 'ul', class => 'ep_report_items' ) );
			}

			# also needs a link
			my $sub_li = $cat_ul->appendChild( $self->repository->make_element( 'li' ) );
			$sub_li->appendChild( $report_plugin->render_action_link );
		}
		else
		{
			$cat_ul = undef;
		}
	}

	$preset->appendChild( $ul );
	push @panels, $preset;

	#custom reports
	push @labels, $repo->html_phrase( "reports_custom" );

	my $custom = $repo->make_element( "div", id=>"custom_report" );
	my $form = $repo->render_form( "get" );

	#add each report to the select component and generate search form if required
	my $report_select = $repo->make_element( "select", name=>"report", id=>"select_report" );
	my %search_forms;
	my $custom_reports = 0;
	foreach my $report_plugin ( @plugins )
	{
		if( $report_plugin->param( "custom" ) )
		{	
			$custom_reports++;
			my $formid = $report_plugin->{searchdatasetid} . "_report";

			#add to select component
			my $id = $report_plugin->{report};
			my $option = $repo->make_element( "option", value => $report_plugin->get_subtype, form => $formid );
			$option->appendChild( $report_plugin->render_title );
			$report_select->appendChild( $option );

			#create search form
			
			#get report dataset and appropriate search config
			my $report_ds = $repo->dataset( $report_plugin->{searchdatasetid} );
			my $sconf = $report_ds->search_config( $report_plugin->{sconf} ) ;
		
			my $search = EPrints::Search->new(
		                keep_cache => 1,
	                	session => $repo,
		                dataset => $report_ds,
		                %{$sconf}
			);

			#generate the form
			my $frag = $self->render_search_fields( $search );
			$search_forms{$formid} = $frag unless exists $search_forms{$formid};
		}	
	}
	$form->appendChild( $report_select );
	$form->appendChild( $repo->render_hidden_field( "screen", $self->{screenid} ) );

	#render possible search forms
	foreach my $formid (keys %search_forms)
	{
		my $table = $repo->make_element( "table", class=>"ep_search_fields", id=>$formid, style=>"display: none" );
	        $form->appendChild( $table );
	        $table->appendChild( $search_forms{$formid} );
	}

	$form->appendChild( $self->render_controls );
	$custom->appendChild( $form );

	#javascript for changing forms based on report selection
	$custom->appendChild( $repo->make_javascript( 'initReportForm();' ) );

	if( $custom_reports ) #set up tab interface
	{
		my @labels;
	        my @panels;

		push @labels, $repo->html_phrase( "reports_preset" );
		push @labels, $repo->html_phrase( "reports_custom" );

		push @panels, $preset;
		push @panels, $custom;

		return $repo->xhtml->tabs(\@labels, \@panels );
	}
	else
	{	
		return $preset;
	}
}

sub render_search_fields
{
        my( $self, $search ) = @_;

        my $frag = $self->{session}->make_doc_fragment;

        foreach my $sf ( $search->get_non_filter_searchfields )
        {
	         $frag->appendChild(
                        $self->{session}->render_row_with_help(
                                help_prefix => $sf->get_form_prefix."_help",
                                help => $sf->render_help,
                                label => $sf->render_name,
                                field => $sf->render,
                                no_toggle => ( $sf->{show_help} eq "always" ),
                                no_help => ( $sf->{show_help} eq "never" ),
        	) );
        }

        return $frag;
}

sub render_controls
{
	my( $self ) = @_;

	my $div = $self->{session}->make_element(
                "div" ,
                class => "ep_search_buttons" );
        $div->appendChild( $self->{session}->render_action_buttons(
                _order => [ "search", "newsearch" ],
                newsearch => $self->{session}->phrase( "lib/searchexpression:action_reset" ),
                search => $self->{session}->phrase( "lib/searchexpression:action_search" ) )
        );

	return $div;
}

sub render
{
	my( $self ) = @_;

	# if users access Screen::Report directly we want to display some sort of menu
	# where users can select viewable reports
	if( "EPrints::Plugin::".$self->get_id eq __PACKAGE__ && $self->{processor}->{action} ne "search" )
	{	
		return $self->render_splash_page;
	}

	my $repo = $self->repository;

	my $chunk = $repo->make_doc_fragment;

	$chunk->appendChild( $self->render_export_bar );

	my $items = $self->items;
	if( !defined $items || $items->count == 0 )
	{
		# No items message
	}

	my $item_ids = defined $items ? $items->ids : [];

	my $json = "[".join(',',@$item_ids)."]";

        my $url = $repo->current_url( host => 1 );
        my $parameters = URI->new;
        $parameters->query_form(
                $self->hidden_bits,
        );
        $parameters = $parameters->query;
		
	my $ds = $repo->dataset( $self->param( 'datasetid' ) ) if defined $self->param( 'datasetid' );
	my $prefix = $ds->base_id if defined $ds;

	# the main <div>
	my $container_id = sprintf( "ep_report_%s\_container", $self->get_report );

	#update javascript parameters if coming from a search request
	if( $self->{processor}->{action} eq "search" )
	{
		my $plugin = $self->{processor}->{report};
		$plugin =~ s/:/%3A/g;
		$parameters = "screen=$plugin";
		$prefix = $self->{processor}->{datasetid};
		$container_id = sprintf( "ep_report_%s\_container", $self->{processor}->{report_plugin}->{report} );
	}

	$chunk->appendChild( $repo->make_javascript( <<"EOJ" ) );
document.observe("dom:loaded", function() {

	new EPrints_Screen_Report_Loader( {
		ids: $json,
		step: 20,
		prefix: '$prefix',
		url: '$url',
		parameters: '$parameters',
		container_id: '$container_id' 
	} ).execute();

});
EOJ
	$chunk->appendChild( $repo->make_element( 'div', class => 'ep_report_page', id => $container_id ) );

	return $chunk;
}


sub render_export_bar
{
	my( $self ) = @_;

	my $repo = $self->repository;

	my $chunk = $repo->make_doc_fragment;

	my @plugins = $self->export_plugins;
	return $chunk unless( scalar( @plugins ) || defined( $repo->config( $self->{export_conf}, "exportfields" ) ) );

	my $report_ds = $repo->dataset( $self->{datasetid} );
	my $form = $self->render_form;
	$form->setAttribute( method => "get" );

	if( $self->{processor}->{action} eq "search" )
        {
		$form->appendChild( $repo->render_hidden_field( "search",  $self->{processor}->{search}->serialise) );
	}

	if( !defined( $repo->config( $self->{export_conf}, "exportfields" ) ) )
	{
		#no custom export fields defined, use export plugins designed for this report
		my $select = $form->appendChild( $repo->render_option_list(
			name => 'export',
			values => [map { $_->get_subtype } @plugins],
			labels => {map { $_->get_subtype => $_->get_name } @plugins},
		) );
	}
	else
	{
		#provide list of default export plugins for reports
		@plugins = $self->export_plugins( "generic" );
		my $select = $form->appendChild( $repo->render_option_list(
			name => 'export',
			values => [map { $_->get_subtype } @plugins],
			labels => {map { $_->get_subtype => $_->get_name } @plugins},
		) );


		#create labels and panels for tabbed interfaced
		my $xml = $repo->xml;
		my $xhtml = $repo->xhtml;

		#allow user to choose which fields they want to export
		my $export_options = $repo->make_element( "div" );

		foreach my $key ( keys %{$repo->config( $self->{export_conf}, "exportfields" )} )
		{
			#create a new list			
			my $ul = $repo->make_element( "ul",
	                	style => "list-style-type: none"
	        	);
			
			my $count = 0; #count how many fields we add
			foreach my $fieldname( @{$repo->config( $self->{export_conf}, "exportfields" )->{$key}} )
			{
					my $field = EPrints::Utils::field_from_config_string( $report_ds, $fieldname );
			
					$count++;

	 				my $li = $repo->make_element( "li" );
		                	$ul->appendChild( $li );

	        		        my $checkbox = $repo->make_element( "input", type => "checkbox", id => $fieldname, name => $fieldname, value => $fieldname );	
					if( ( grep { $fieldname eq $_ } @{$repo->config( $self->{export_conf}, "exportfield_defaults" )} ) || ( scalar( @{$repo->config( $self->{export_conf}, "exportfield_defaults" )} ) == 0 ) )
					{
						#only check defaults or check everything if defaults not defined
						$checkbox->setAttribute( "checked", "yes" );
					}

			                my $label = $repo->make_element( "label", for => $fieldname );
        			        $label->appendChild( $field->render_name );

	                		$li->appendChild( $checkbox );
	        	        	$li->appendChild( $label );
			}
			if( $count ) #only add options if we have any fields to show
			{
				my $div = $repo->make_element( "div", class=>"report_export_options" );
				$div->appendChild( my $h = $repo->make_element( "h4" ) );
				$h->appendChild( $repo->html_phrase( "exportfields:$key" ) );	
				$div->appendChild( $ul );
				$export_options->appendChild( $div );
			}
       		}
		$form->appendChild( $export_options );
	}

	$form->appendChild( 
		$repo->render_button(
			name => "_action_export",
			class => "ep_form_action_button",
			value => $repo->phrase( 'cgi/users/edit_eprint:export' )
	) );

	#create a collapsible box
	my $imagesurl = $repo->current_url( path => "static", "style/images" );
	my %options;
	$options{session} = $repo;
        $options{id} = "ep_report_export";
        $options{title} = $repo->html_phrase( "export_title" );
        $options{collapsed} = 1;
	$options{content} = $form;
        $options{show_icon_url} = "$imagesurl/multi_down.png";
	$options{hide_icon_url} = "$imagesurl/multi_up.png";

	my $box = $repo->make_element( "div", style=>"text-align: left" );
	$box->appendChild( EPrints::Box::render( %options ) );
	$chunk->appendChild( $box );

	return $chunk;
}

### utility methods

# TODO should use "JSON" package
sub to_json
{
        my( $self, $object ) = @_;

	return "" if( !defined $object );

# UTF-8 issues:
#	return JSON->new->utf8(1)->encode( $object );

        if( ref( $object ) eq 'HASH' )
        {
                my @stuff;
                while( my( $k, $v ) = each( %$object ) )
                {
                        next if( !EPrints::Utils::is_set( $v ) );       # or 'null' ?
                        push @stuff, EPrints::Utils::js_string( $k ).':'.$self->to_json( $v )
                }
                return '{' . join( ",", @stuff ) . '}';
        }
        elsif( ref( $object ) eq 'ARRAY' )
        {
                my @stuff;
                foreach( @$object )
                {
                        next if( !EPrints::Utils::is_set( $_ ) );
                        push @stuff, $self->to_json( $_ );
                }
                return '[' . join( ",", @stuff ) . ']';
        }

        return EPrints::Utils::js_string( $object );
}

sub export_plugins
{
        my( $self, $generic ) = @_;

	my @plugin_ids;
	if( $generic )
	{
 		@plugin_ids = $self->repository->plugin_list(
                	type => "Export",
	                can_accept => "report/generic",
        	        is_visible => "staff",
			is_advertised => 1,
	        );
	}
	else
	{
        	@plugin_ids = $self->repository->plugin_list(
                	type => "Export",
	                can_accept => "report/".$self->get_report,
        	        is_visible => "staff",
			is_advertised => 1,
	        );
        }
	my @plugins;
	foreach my $id ( @plugin_ids )
        {
                my $p = $self->repository->plugin( "$id" ) or next;
                push @plugins, $p;
        }

        return @plugins;
}

sub report_plugins
{
	my( $self ) = @_;

	# sf2 - can't list via type => "Search::Report" ? 
        my @plugin_ids = $self->repository->plugin_list(
                type => "Screen",
        );

        my @plugins;
	foreach my $id ( @plugin_ids )
        {
		next if( $id !~ /^Screen::Report::/ );	# note this also filters out $self (aka Screen::Report)

                my $p = $self->repository->plugin( "$id" );
		next if( !defined $p || !$p->can_be_viewed );

                push @plugins, $p;
        }

        return @plugins;
}


1;
