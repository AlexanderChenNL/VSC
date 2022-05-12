using StatsBase
using Fontconfig

# I do not see a reason to create a function just to call `sort` with some
# specific keywords.
#
# function sorting_array(a)
#   return sort(a, by = last, rev =true)
# end

# In Julia, there is a convention in which functions that modifies the inputs
# should have `!` appended to its name.
function fill_key_value!(key_value, frequency_array, new_node_counter)
    # Here, we do not need to return `key_value` because it is a dictionary,
    # which is passed by reference. Thus, we actually modify it here.

    # This branch is necessary when the text has only one symbol, like
    # "aaaaaaaaaa". The previous version of the code was failing in this case.
    if length(frequency_array) == 1
        last_sorted = pop!(frequency_array)
        key_value[first(last_sorted)] = ("root", last(last_sorted), '0')

    else
        last_sorted        = pop!(frequency_array)
        second_last_sorted = pop!(frequency_array)

        # If the frequency array is empty after removing two elements, we have a
        # root node. This kind of verification removes the necessity of having a
        # branch for the case in which the length of frequency array is 2.
        new_node_type = isempty(frequency_array) ? :root : :new_node
        new_node = new_node_type == :new_node ? string(new_node_counter) : "root"

        # Sometimes the compiler can get redundant operations, sometimes not.
        # Hence, it is good to make sure that we are not computing the same
        # thing more than once.
        aux = last(second_last_sorted) + last(last_sorted)

        key_value[first(second_last_sorted)] = (new_node, aux, '1')
        key_value[first(last_sorted)]        = (new_node, aux, '0')

        # If we are not in a root node, push the new node to the frequency array
        # and sort it once more.
        if new_node_type == :new_node
            # Here, it is better to perform an in-place sort and use the same
            # array instead of creating a new one.
            #
            # I think this can be highly improved if a list is used. In this
            # case, the push can be performed in the correct place, avoiding a
            # sorting algorithm.
            push!(frequency_array, (new_node, aux))
            sort!(frequency_array; by = last, rev = true)

            return fill_key_value!(key_value, frequency_array, new_node_counter + 1)
        end
    end

    return nothing
end

# We use a new approach to this function. It always return `nothing` and the
# encoding is written to the `buffer`. Hence, we remove the type instability,
# leading to a better performance.
function find_encoding!(buffer, key_value, key)
    # We have sure that all tuples and arrays are accessed within allowed
    # ranges. Thus, `@inbounds` can help to slightly increase the performance.
    @inbounds if key == "root"
        return nothing
    else
        write(buffer, key_value[key][3])
        return find_encoding!(buffer, key_value, key_value[key][1])
    end
end

function huffman_encoding(input::AbstractString)
    # Obtain the occurrence frequency of each character.
    #
    # Here, we do not split the input string into a vector of strings, one
    # element for each character. We obtain a dictionary in which the keys are
    # `Char` and convert them to `String` when creating the `frequency_array`.
    # Thus, we can save computational burden and allocations.
    char_frequency = countmap(input)

    # The variable `NewNode_array` seems to be acting just as a counter. Notice
    # that inside `fill_key_value`, only the length of the frequency array is
    # used to check which action must be performed. Hence, we will use just a
    # counter to save allocations.
    new_node_counter = 1

    # Create the frequency array by sorting (descending) the dictionary
    # `char_frequency` by the frequency.
    frequency_array = sort(
        [(string(x), char_frequency[x]) for x in keys(char_frequency)];
        by = last,
        rev = true
    )

    key_value     = Dict{String, Tuple{String, Integer, Char}}()
    encoding_dict = Dict{String, String}()

    fill_key_value!(key_value, frequency_array, new_node_counter)

    # Every time you need to build a string and do not have a way to guess its
    # size, then it is better to create an `IOBuffer` and write to it instead of
    # using arrays or strings.
    encoding_dict_buffer = IOBuffer()

    # We do not need to isolate the keys by creating a vector. We just need to
    # iterate through them.
    for k in keys(char_frequency)
        find_encoding!(encoding_dict_buffer, key_value, string(k))

        # Now, `encoding_buffer` contains the encoded string for the character.
        # We using `take!` to return the bytes, and `String` to convert them to
        # a string. After that, the buffer is empty and we can continue the
        # loop.
        encoding_dict[string(k)] = String(take!(encoding_dict_buffer))
    end

    # We will also use a buffer to create the encoded string instead of the old
    # approach of concatenating strings. The reason is the same as previously
    # mentioned (this approach leads to a much better performance if the output
    # string size is not know).
    encoded_string_buffer = IOBuffer()

    for i in input
        write(encoded_string_buffer, encoding_dict[string(i)])
    end

    encoded_string = String(take!(encoded_string_buffer))

    return encoded_string, encoding_dict
end

function huffman_decoding(encoded_string, encoding_dict)
    # We need to sort (descending) the encoding dictionary to allow to rebuild
    # the message. Wouldn't it be better to sort as the encoding dictionary is
    # being built? Of course we need to use another structure besides `Dict`
    encoding_array = sort(
        [(x, encoding_dict[x], length(encoding_dict[x])) for x in keys(encoding_dict)];
        by = last,
        rev = true
    )

    decoded_string = ""

    decoded_string, result = rebuild_message(encoded_string, encoding_array)

    # Check for errors in decoding.
    !result && error("The string could not be decoded properly.")

    return decoded_string
end

# Here, we use multiple dispatch to avoid creating an empty decoded string in
# `huffman_decoding` that does not seem to have a purpose. This modification
# only makes the code more "Julian".
function rebuild_message(encoded_string, encoding_array)
    return rebuild_message("", encoded_string, encoding_array)
end

function rebuild_message(decoded_string, encoded_string, encoding_array)
    # The return in the previous version was not working because there was many
    # recursions. You need to track until a branch reaches the final of the
    # encoded string. In this case, you must mark that the end was reached and
    # return the encoded string in every recursion. Hence, this version of
    # `rebuild_message` returns a tuple. The first element is the current
    # decoded string whereas the second element is if the algorithm reached the
    # end of the processing string.

    # We have sure that all tuples and arrays are accessed within allowed
    # ranges. Thus, `@inbounds` can help to slightly increase the performance.
    @inbounds for i in encoding_array
        # If the input string is empty, we just need to return it. We also
        # indicate that we reached the end of the processing here.
        if isempty(encoded_string)
            return decoded_string, true
        end

        # We need to check if the input string has at least `i[3]` characters.
        # Otherwise, we can access an undefined region of the memory.
        #
        # Notice that this code WILL NOT WORK with UTF-8 characters because they
        # can be represented by more than one byte. The conversion is not
        # trivial, see the functions `nextind` and `textwidth`.

        if (length(encoded_string) ≥ i[3]) && (encoded_string[1:i[3]] == i[2])
            # Now, we obtain a view of the string without the processed part and
            # continue the loop. Notice that we do not need to check if we have
            # access to the index `i[3] + 1` because `SubString` returns an
            # empty string in this case.

            new_decoded_string, final_processing = rebuild_message(
                # Concatenating strings using `a * b` is clearer than using
                # `string(a, b)`.
                decoded_string * i[1],
                SubString(encoded_string, i[3] + 1),
                encoding_array
            )

            # If we reached the final processing, just return the current
            # decoded string. Otherwise, go to the next symbol.
            if final_processing
                return new_decoded_string, true
            end
        end

        # If the previous verification is not successful, we need to go to the
        # next symbol.
    end

    # If we reach this return, it means that a symbol was not decoded. Hence, we
    # need to inform that the final processing was not achieved.
    return decoded_string, false
end

#                                    TESTS
# ==============================================================================

using Test

a = """Alice was beginning to get very tired of sitting by her sister on
the bank, and of having nothing to do: once or twice she had
peeped into the book her sister was reading, but it had no
pictures or conversations in it, `and what is the use of a book,'
thought Alice `without pictures or conversation?'
So she was considering in her own mind (as well as she could,
for the hot day made her feel very sleepy and stupid), whether
the pleasure of making a daisy-chain would be worth the
trouble of getting up and picking the daisies, when suddenly a White Rabbit with pink eyes ran close by her. There was nothing so VERY remarkable in that; nor did Alice
think it so VERY much out of the way to hear the Rabbit say
to itself, `Oh dear! Oh dear! I shall be late!' (when she thought
it over afterwards, it occurred to her that she ought to have
wondered at this, but at the time it all seemed quite natural);
but when the Rabbit actually TOOK A WATCH OUT OF ITS
WAISTCOAT- POCKET, and looked at it, and then hurried
on, Alice started to her feet, for it flashed across her mind that
she had never before seen a rabbit with either a waistcoat-pocket, or a watch to take out of it, and
burning with curiosity, she ran across the field after it, and fortunately was just in time to see it pop
down a large rabbit-hole under the hedge."""

encoded_string, encoding_dict = huffman_encoding(a)
decoded_string = huffman_decoding(encoded_string, encoding_dict)

@test decoded_string == a
