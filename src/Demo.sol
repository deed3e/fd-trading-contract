// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

contract Demo {
    struct Student {
        uint256 id;
        string name;
    }

    Student[] public list;

    function addStudent(uint256 _id, string memory _name) external {
        Student memory st;
        st.id = _id;
        st.name = _name;
        list.push(st);
        emit StudentAdd(_id, _name);
    }

    event StudentAdd(uint256 id, string name);
}