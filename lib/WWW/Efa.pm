package WWW::Efa;

use strict;
use warnings;
use 5.010;

use base 'Exporter';

use XML::LibXML;
use WWW::Mechanize;

our @EXPORT_OK = ();
my $VERSION = '1.3+git';

sub post_time {
	my ($post, $conf) = @_;
	my $time;

	if ($conf->{'depart'} || $conf->{'time'}) {
		$post->{'itdTripDateTimeDepArr'} = 'dep';
		$time = $conf->{'depart'} || $conf->{'time'};
	}
	else {
		$post->{'itdTripDateTimeDepArr'} = 'arr';
		$time = $conf->{'arrive'};
	}

	if ($time !~ / ^ [0-2]? \d : [0-5]? \d $ /x) {
		return WWW::Efa::Error->new(
			'internal', 'conf', ['time', $time, 'Must match HH:MM']
		);
	}
	@{$post}{'itdTimeHour', 'itdTimeMinute'} = split(/:/, $time);
}

sub post_date {
	my ($post, $date) = @_;

	if ($date !~ /^ [0-3]? \d \. [01]? \d \. (?: \d{4} )? $/x) {
		return WWW::Efa::Error->new(
			'internal', 'conf', ['date', $date, 'Must match DD.MM.[YYYY]']
		);
	}
	@{$post}{'itdDateDay', 'itdDateMonth', 'itdDateYear'} = split(/\./, $date);
	$post->{'itdDateYear'} //= (localtime(time))[5] + 1900;
}

sub post_exclude {
	my ($post, @exclude) = @_;
	my @mapping = qw{
		zug s-bahn u-bahn stadtbahn tram stadtbus regionalbus
		schnellbus seilbahn schiff ast sonstige
	};

	foreach my $exclude_type (@exclude) {
		my $ok = 0;
		for my $map_id (0 .. $#mapping) {
			if ($exclude_type eq $mapping[$map_id]) {
				$post->{"inclMOT_${map_id}"} = undef;
				$ok = 1;
			}
		}
		if (not $ok) {
			return WWW::Efa::Error->new(
				'internal', 'conf',
				[
					'exclude',
					join(q{ }, @exclude),
					'Must consist of ' . join(q{ }, @mapping)
				]
			);
		}
	}
}

sub post_prefer {
	my ($post, $prefer) = (@_);

	given($prefer) {
		when('speed')  { $post->{'routeType'} = 'LEASTTIME' }
		when('nowait') { $post->{'routeType'} = 'LEASTINTERCHANGE' }
		when('nowalk') { $post->{'routeType'} = 'LEASTWALKING' }
		default {
			return WWW::Efa::Error->new(
				'internal', 'conf',
				['prefer', $prefer, 'Must be either speed, nowait or nowalk']
			);
		}
	}
}

sub post_include {
	my ($post, $include) = @_;

	given ($include) {
		when ('local') { $post->{'lineRestriction'} = 403 }
		when ('ic')    { $post->{'lineRestriction'} = 401 }
		when ('ice')   { $post->{'lineRestriction'} = 400 }
		default {
			return WWW::Efa::Error->new(
				'internal', 'conf',
				['include', $include, 'Must be one of local/ic/ice']
			);
		}
	}
}

sub post_walk_speed {
	my ($post, $walk_speed) = @_;

	if ($walk_speed ~~ ['normal', 'fast', 'slow']) {
		$post->{'changeSpeed'} = $walk_speed;
	}
	else {
		return WWW::Efa::Error->new(
			'internal', 'conf',
			['walk_speed', $walk_speed, 'Must be normal, fast or slow']
		);
	}
}

sub post_place {
	my ($post, $which, $place, $stop, $type) = @_;

	if (not ($place and $stop)) {
		return WWW::Efa::Error->new(
			'internal', 'conf',
			['place', "'$place' '$stop'", "Need at least two elements for ${which}"]
		);
	}

	$type //= 'stop';

	@{$post}{"place_${which}", "name_${which}"} = ($place, $stop);

	if ($type ~~ [qw[address poi stop]]) {
		$post->{"type_${which}"} = $type;
	}
}

sub create_post {
	my ($conf) = @_;
	my $post = {};

	post_place($post, 'origin', @{$conf->{'from'}});

	post_place($post, 'destination', @{$conf->{'to'}});

	if ($conf->{'via'}) {
		post_place($post, 'via', @{$conf->{'via'}});
	}
	if ($conf->{'arrive'} || $conf->{'depart'} || $conf->{'time'}) {
		post_time($post, $conf);
	}
	if ($conf->{'date'}) {
		post_date($post, $conf->{'date'});
	}
	if ($conf->{'exclude'}) {
		post_exclude($post, @{$conf->{'exclude'}});
	}
	if ($conf->{'max_interchanges'}) {
		$post->{'maxChanges'} = $conf->{'max_interchanges'};
	}
	if ($conf->{'prefer'}) {
		post_prefer($post, $conf->{'prefer'});
	}
	if ($conf->{'proximity'}) {
		$post->{'useProxFootSearch'} = 1;
	}
	if ($conf->{'include'}) {
		post_include($post, $conf->{'include'});
	}
	if ($conf->{'walk_speed'}) {
		post_walk_speed($post, $conf->{'walk_speed'});
	}
	if ($conf->{'bike'}) {
		$post->{'bikeTakeAlong'} = 1;
	}

	return $post;
}

sub parse_initial {
	my ($tree) = @_;

	my $con_part = 0;
	my $con_no;
	my $cons;

	my $xp_td = XML::LibXML::XPathExpression->new('//table//table/tr/td');
	my $xp_img = XML::LibXML::XPathExpression->new('./img');

	foreach my $td (@{$tree->findnodes($xp_td)}) {

		my $colspan = $td->getAttribute('colspan') // 0;
		my $class   = $td->getAttribute('class')   // q{};

		if ( $colspan != 8 and $class !~ /^bgColor2?$/ ) {
			next;
		}

		if ($colspan == 8) {
			if ($td->textContent() =~ / (?<no> \d+ ) \. .+ Fahrt /x) {
				$con_no = $+{'no'} - 1;
				$con_part = 0;
				next;
			}
		}

		if ($class =~ /^bgColor2?$/) {
			if ($class eq 'bgColor' and ($con_part % 2) == 1) {
				$con_part++;
			}
			elsif ($class eq 'bgColor2' and ($con_part % 2) == 0) {
				$con_part++;
			}
		}

		if (
			defined $con_no and not $td->exists($xp_img)
			and $td->textContent() !~ /^\s*$/
			)
		{
			push(@{$cons->[$con_no]->[$con_part]}, $td->textContent());
		}
	}

	if (defined $con_no) {
		return $cons;
	}
	else {
		return WWW::Efa::Error->new(
			'efa.vrr.de', 'no data'
		);
	}
}

sub parse_pretty {
	my ($con_parts) = @_;
	my $elements;
	my @next_extra;

	for my $con (@{$con_parts}) {

		my $hash;

		# Note: Changes @{$con} elements
		foreach my $str (@{$con}) {
			$str =~ s/[\s\n\t]+/ /gs;
			$str =~ s/^ //;
			$str =~ s/ $//;
		}

		if (@{$con} < 5) {
			@next_extra = @{$con};
			next;
		}

		# @extra may contain undef values
		foreach my $extra (@next_extra) {
			if ($extra) {
				push(@{$hash->{'extra'}}, $extra);
			}
		}
		@next_extra = undef;

		if ($con->[0] !~ / \d{2} : \d{2} /ox) {
			splice(@{$con}, 0, 0, q{});
			splice(@{$con}, 4, 0, q{});
			$con->[7] = q{};
		}
		elsif ($con->[4] =~ / Plan: \s ab /ox) {
			push(@{$hash->{'extra'}}, splice(@{$con}, 4, 1));
		}

		foreach my $extra (splice(@{$con}, 8, -1)) {
			push (@{$hash->{'extra'}}, $extra);
		}

		$hash->{'dep_time'}   = $con->[0];
		# always "ab"           $con->[1];
		$hash->{'dep_stop'}   = $con->[2];
		$hash->{'train_line'} = $con->[3];
		$hash->{'arr_time'}   = $con->[4];
		# always "an"           $con->[5];
		$hash->{'arr_stop'}   = $con->[6];
		$hash->{'train_dest'} = $con->[7];

		push(@{$elements}, $hash);
	}
	return($elements);
}

sub new {
	my ($obj, %conf) = @_;
	my $ref = {};

	$ref->{'config'} = \%conf;
	$ref->{'post'}  = create_post(\%conf);

	return bless($ref, $obj);
}

sub submit {
	my ($self, %conf) = @_;

	my $firsturl
		= 'http://efa.vrr.de/vrr/XSLT_TRIP_REQUEST2?language=de&itdLPxx_transpCompany=vrr';

	$self->{'mech'} = WWW::Mechanize->new(
		autocheck => 1,
		timeout   => $conf{'timeout'} // 10,
	);

	$self->{'mech'}->get($firsturl);
	$self->{'mech'}->submit_form(
		form_name => 'jp',
		fields    => $self->{'post'},
	);

	# XXX (workaround)
	# The content actually is iso-8859-1. But HTML::Message doesn't actually
	# decode character strings when they have that encoding. However, it
	# doesn't check for latin-1, which is an alias for iso-8859-1.

	$self->{'html_reply'} = $self->{'mech'}->response()->decoded_content(
		charset => 'latin-1'
	);
}

sub parse {
	my ($self) = @_;

	my $tree = XML::LibXML->load_html(
		string => $self->{'html_reply'},
	);

	my $raw_cons = parse_initial($tree);

	for my $raw_con (@{$raw_cons}) {
		push(@{$self->{'connections'}}, parse_pretty($raw_con));
	}
	$self->{'tree'} = $tree;
}

sub check_ambiguous {
	my ($self) = @_;
	my $tree = $self->{'tree'};

	my $xp_select = XML::LibXML::XPathExpression->new('//select');
	my $xp_option = XML::LibXML::XPathExpression->new('./option');

	foreach my $select (@{$tree->findnodes($xp_select)}) {

		my @possible = ($select->getAttribute('name'));

		foreach my $val ($select->findnodes($xp_option)) {
			push(@possible, $val->textContent());
		}

		return WWW::Efa::Error->new(
			'efa.vrr.de', 'ambiguous',
			\@possible
		);
	}
}

sub check_no_connections {
	my ($self) = @_;
	my $tree = $self->{'tree'};

	my $xp_err_img = XML::LibXML::XPathExpression->new(
		'//td/img[@src="images/ausrufezeichen.jpg"]');

	my $err_node = $tree->findnodes($xp_err_img)->[0];

	if ($err_node) {
		return WWW::Efa::Error->new(
			'efa.vrr.de', 'error',
			$err_node->parentNode()->parentNode()->textContent()
		);
	}
}

sub connections {
	my ($self) = @_;

	return(@{$self->{'connections'}});
}

1;