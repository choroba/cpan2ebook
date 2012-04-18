package PodBook::CpanSearch;

use Mojo::Base 'Mojolicious::Controller';
use Mojo::Headers;
use Regexp::Common 'net';
use File::Slurp;
use File::Temp 'tempfile';
use JSON;
use MetaCPAN::API;

use EPublisher;
use EPublisher::Source::Plugin::MetaCPAN;
use EPublisher::Target::Plugin::EPub;
use EPublisher::Target::Plugin::Mobi;

use PodBook::Utils::Request;
use PodBook::Utils::CPAN::Names;

our $VERSION = 0.1;

# This action will render a template
sub form {
    my $self = shift;

    # if textfield is empty we just display the starting page
    unless ($self->param('in_text')) {
        # EXIT
        my @messages = (
            'The CPAN as your EBook.',
            'Cook your Book.',
            'Read POD everywhere.',
            'Read Perl-Module-Documentation secretly in your bed at night.',
            'POD: Pod On Demand.',
        );
        my $message = @messages[ int rand scalar @messages ];
        $self->render( message => $message );
        return;
    }
    # otherwise we continue by checking the input

    # check the type of button pressed
    my $type;
    if ($self->param('MOBI')) {
        $type = 'mobi';
    }
    elsif ($self->param('EPUB')) {
        $type = 'epub';
    }
    else {
        # EXIT if unknown
        $self->render( message => 'ERROR: Type of ebook unknown.' );
        return;
    }

    # check if the module name in the text field is some what valid
    my ($module_name) = $self->param('in_text') =~ m/^([\d\w\-:]+)$/;

    if ( !$module_name ) {
        # EXIT if not matching
        $self->render( message => 'ERROR: Module name not accepted.' );
        return;
    }

    # check the remote IP... just to be sure!!! (like taint mode)
    my $remote_address;
    my $pattern = $RE{net}{IPv4};
    if ($self->tx->remote_address =~ m/^($pattern)$/) {
        $remote_address = $1;
    }
    else {
        # EXIT if not matching...
        # TODO: IPv6 will probably be a problem here...
        $self->render( message => 'ERROR: Are you a HACKER??!!.' );
        return;
    }


    # INPUT SEEMS SAVE!!!
    # So we can go on and try to process this request

    # lets load some values from the config file
    my $config            = $self->config;
    my $userblock_seconds = $config->{userblock_seconds};
    my $cpan_namespaces_source = $config->{cpan_namespaces_source};

    # translate the module/releasename to a releasename
    # EBook::MOBI -> EBook-MOBI
    # EBook-MOBI  -> EBook-MOBI
    my $t = PodBook::Utils::CPAN::Names->new('DB', $cpan_namespaces_source);
    $module_name = $t->translate_any2release($module_name);
    unless ( $module_name ) {
        # EXIT if no releasename found
        $self->render( message => 'ERROR: Module name not found.' );
        return;
    }

    # we need to know the most recent version of the module requested
    # therefore we will ask MetaCPAN

    # search metacpan
    my $mcpan   = MetaCPAN::API->new;
    my $q       = sprintf "distribution:%s AND status:latest", $module_name;
    my $release = $mcpan->release(
        search => {
            q      => $q,
            fields => "distribution,version,name",
            size   => 1
        },
    );

    # we fill the result into this variable
    my $module_version;
    if ( $release ) {

        $module_version = $release->{hits}->{hits}->[0]->{fields}->{version};
        
        unless ( $module_version ) {
            # EXIT if there is no version...
            # this seems to mean, that the module does not exist
            $self->render(
                message => "ERROR: Module not found"
            );

            return;
        }

    }
    else {
        # EXIT if we can't reach MetaCPAN
        $self->render(
            message => "ERROR: Can't reach MetaCPAN"
        );

        return;
    }

    # finaly we have everything we need to build a request object!
    my $book_request = PodBook::Utils::Request->new(
        $remote_address,
        "metacpan::$module_name-$module_version",
        $type,
        $userblock_seconds,
        'pod2cpan_webservice',
    );

    # we check if the user is using the page to fast
    # TODO: would be nice it this would as the very first in code
    unless ($book_request->uid_is_allowed()) {
        # EXIT if he is to fast
        $self->render(
            message => "ERROR: To many requests from: $remote_address "
            . "- Only one request per $book_request->{uid_expiration} "
            . "seconds allowed."
        );

        return;
    }


    # check if we have the book already in cache
    if ($book_request->is_cached()) {

        # get the book from cache
        my $book = $book_request->get_book();

        # send the book to the client
        $self->send_download_to_client($book,
            "$module_name-$module_version.$type"
        );
    }
    # if the book is not in cache we need to fetch the POD from MetaCPAN
    # and render it into an EBook. We use the EPublisher to do that
    else {
        my $tmp_dir         = $self->config->{tmp_dir};
        my ($fh, $filename) = tempfile(DIR => $tmp_dir, SUFFIX => '.book');
        unlink $filename;

        # build the config for EPublisher
        my %config = ( 
            config => {
                pod2cpan_webservice => {
                    source => {
                        type    => 'MetaCPAN',
                        module => $module_name},
                    target => { 
                        output => $filename,
                        title  => "$module_name-$module_version",
                        author => "Perl",
                        # this option is ignored by "type: epub"
                        htmcover => "<h3>Perl Module Documentation</h3><h1>$module_name</h1>Module version: $module_version<br />Source: <a href='https://metacpan.org/'>https://metacpan.org</a><br />Powered by: <a href='http://perl-services.de'>http://perl-services.de</a><br />"
                    }   
                }   
            },  
            debug  => sub {
                print "@_\n";
            },  
        );

        # still building the config (and loading the right modules)
        if ($type eq 'mobi') {
            $config{config}{pod2cpan_webservice}{target}{type} = 'Mobi';
        }
        elsif ($type eq 'epub') {
            $config{config}{pod2cpan_webservice}{target}{type} = 'EPub';
        }
        else {
            # EXIT
            $self->render( message => 'ERROR: unknown book-type' );
        }

        my $publisher = EPublisher->new(
            %config,
            debug => sub{ $self->debug_epublisher( @_ ) },
        );
        
        # This code here would be neccesary if we don't trust the
        # $module_version anymore... since it's a bit 'old' (not even a sec)

        #my $sub_get_release_from_metacpan_source = sub {
            #my $metacpan_source = shift;
            #$self->{metacpan_source_release_version} = 
                #$metacpan_source->{release_version};
        #};
        #$publisher->set_hook_source_ref(
            #$sub_get_release_from_metacpan_source
        #);

        # fetch from MetaCPAN and render
        $publisher->run( [ 'pod2cpan_webservice' ] );


        # TODO: EPublisher should give me the stuff as bin directly
        my $bin = read_file( $filename, { binmode => ':raw' } ) ;
        unlink $filename;
        $book_request->set_book($bin);

        # we finally have the EBook and cache it before delivering
        my $caching_seconds = $config->{caching_seconds};
        $book_request->cache_book($caching_seconds);

        # send the EBook to the client
        $self->send_download_to_client($bin,
            "$module_name-$module_version.$type"
        );
    }

    # if we reach here... something is wrong!
    $self->render( message => 'Book cannot be delivered :-)' );
}

sub debug_epublisher {
    my ($self, $msg) = @_;

    my $debug_string = sprintf "[EPublisher][%s] %s", $$, $msg;
    $self->app->log->debug( $debug_string );
}

sub send_download_to_client {
    my ($self, $data, $name) = @_;

    my $headers = Mojo::Headers->new();
    $headers->add(
        'Content-Type',
        "application/x-download; name=$name"
    );
    $headers->add(
        'Content-Disposition',
        "attachment; filename=$name"
    );
    $headers->add('Content-Description','ebook');
    $self->res->content->headers($headers);

    $self->render_data($data);
}

1;
